// Picks up a screenshot handed off from the Screenshot Stitcher's
// "Send to OCR" button (see Start-ReviewWebServer.ps1's /api/send-to-ocr
// and this server's own /api/pending-image).
//
// Deliberately kept out of app.js: rather than reaching into that file's
// internal job-queue state, this simulates the exact same user action as
// picking a file by hand - it puts the fetched image into #fileInput and
// fires a real 'change' event - so it runs through whatever app.js's own
// file-input handler already does, unmodified. Loaded after app.js, so
// that handler is already attached by the time this runs.
(function () {
  const params = new URLSearchParams(window.location.search);
  if (params.get('handoff') !== '1') return;

  // Strip the query param immediately so a manual refresh doesn't try to
  // re-fetch an image the server has already handed out (and deleted).
  const cleanUrl = window.location.pathname + window.location.hash;
  window.history.replaceState({}, document.title, cleanUrl);

  fetch('/api/pending-image', { cache: 'no-store' })
    .then((res) => {
      if (!res.ok) throw new Error('No pending image (' + res.status + ')');
      let name = 'stitched-screenshot.png';
      const rawName = res.headers.get('X-Original-Name');
      if (rawName) {
        try { name = decodeURIComponent(rawName); } catch (e) { /* keep default */ }
      }
      return res.blob().then((blob) => ({ blob, name }));
    })
    .then(({ blob, name }) => {
      const file = new File([blob], name, { type: blob.type || 'image/png' });
      const fileInput = document.getElementById('fileInput');
      if (!fileInput) { console.error('ocr-handoff: #fileInput not found'); return; }

      const dt = new DataTransfer();
      dt.items.add(file);
      fileInput.files = dt.files;
      fileInput.dispatchEvent(new Event('change', { bubbles: true }));
    })
    .catch((err) => {
      // Nothing to hand off (already consumed, server not reachable, etc.)
      // - this is a normal, silent no-op, not an error state for the user.
      console.info('ocr-handoff: nothing to load —', err.message);
    });
})();
