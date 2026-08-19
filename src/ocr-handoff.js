// Picks up screenshot(s) handed off from the Screenshot Stitcher's
// "Send to OCR" / "Send all to OCR" buttons (see Start-ReviewWebServer.ps1's
// /api/send-to-ocr and this server's own /api/pending-images).
//
// Deliberately kept out of app.js: rather than reaching into that file's
// internal job-queue state, this simulates the exact same user action as
// picking files by hand - it puts the fetched images into #fileInput and
// fires a real 'change' event - so it runs through whatever app.js's own
// file-input handler already does, unmodified. Loaded after app.js, so
// that handler is already attached by the time this runs.
(function () {
  const params = new URLSearchParams(window.location.search);
  if (params.get('handoff') !== '1') return;

  // Strip the query param immediately so a manual refresh doesn't try to
  // re-fetch images the server has already handed out (and deleted).
  const cleanUrl = window.location.pathname + window.location.hash;
  window.history.replaceState({}, document.title, cleanUrl);

  function base64ToBlob(base64, mime) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new Blob([bytes], { type: mime });
  }

  fetch('/api/pending-images', { cache: 'no-store' })
    .then((res) => {
      if (!res.ok) throw new Error('Pending images request failed (' + res.status + ')');
      return res.json();
    })
    .then((items) => {
      if (!items || !items.length) {
        // Nothing waiting - a normal, silent no-op, not an error state.
        console.info('ocr-handoff: nothing to load');
        return;
      }
      const fileInput = document.getElementById('fileInput');
      if (!fileInput) { console.error('ocr-handoff: #fileInput not found'); return; }

      const dt = new DataTransfer();
      items.forEach((item, i) => {
        let name = item.name;
        if (!name) name = items.length > 1 ? `stitched-screenshot-${i + 1}.png` : 'stitched-screenshot.png';
        const blob = base64ToBlob(item.data, 'image/png');
        dt.items.add(new File([blob], name, { type: 'image/png' }));
      });
      fileInput.files = dt.files;
      fileInput.dispatchEvent(new Event('change', { bubbles: true }));
    })
    .catch((err) => {
      // Nothing to hand off (already consumed, server not reachable, etc.)
      // - this is a normal, silent no-op, not an error state for the user.
      console.info('ocr-handoff: nothing to load —', err.message);
    });
})();
