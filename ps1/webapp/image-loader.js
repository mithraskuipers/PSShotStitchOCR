// Normalizes screenshots from any source (drag/drop, <input type=file>, or
// fetched from the local review server started by RegionScreenshot.ps1)
// into one shape:
//   { id, name, blob, blobUrl, width, height, thumbUrl }
// Full-resolution RGB pixel data is decoded on demand (loadFullImage) at
// stitch time rather than kept for every entry up front, so reviewing a
// session with a lot of screenshots doesn't hold dozens of full-size
// decoded bitmaps in memory at once.
window.ShotStitcher = window.ShotStitcher || {};

window.ShotStitcher.Loader = (function () {
  const THUMB_MAX_W = 220;
  let uidCounter = 0;
  function nextId() { return 's' + (++uidCounter); }

  function loadImageEl(url) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('Could not decode image'));
      img.src = url;
    });
  }

  // blob: a Blob/File. name: display name (used for natural sort + output).
  async function fromBlob(blob, name) {
    const blobUrl = URL.createObjectURL(blob);
    const imgEl = await loadImageEl(blobUrl);
    const thumbUrl = makeThumb(imgEl);
    return {
      id: nextId(),
      name,
      blob,
      blobUrl,
      width: imgEl.naturalWidth,
      height: imgEl.naturalHeight,
      thumbUrl,
      included: true,
    };
  }

  function makeThumb(imgEl) {
    const scale = Math.min(1, THUMB_MAX_W / imgEl.naturalWidth);
    const w = Math.max(1, Math.round(imgEl.naturalWidth * scale));
    const h = Math.max(1, Math.round(imgEl.naturalHeight * scale));
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    c.getContext('2d').drawImage(imgEl, 0, 0, w, h);
    return c.toDataURL('image/png');
  }

  // Decodes an entry's blob to full-resolution RGB pixel data, in the
  // {width, height, data:Uint8Array} shape the stitch engine expects.
  async function loadFullImage(entry) {
    const imgEl = await loadImageEl(entry.blobUrl);
    const c = document.createElement('canvas');
    c.width = imgEl.naturalWidth; c.height = imgEl.naturalHeight;
    const ctx = c.getContext('2d');
    // Opaque white backdrop first: mirrors the PS engine's conversion of
    // any source pixel format to a 24bpp (no-alpha) bitmap before the
    // pixel math runs.
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, c.width, c.height);
    ctx.drawImage(imgEl, 0, 0);
    const imageData = ctx.getImageData(0, 0, c.width, c.height);
    return window.ShotStitcher.Engine.fromImageData(imageData);
  }

  function extOf(name) {
    const i = name.lastIndexOf('.');
    return i >= 0 ? name.slice(i + 1).toLowerCase() : '';
  }

  const SUPPORTED_EXT = new Set(['png', 'bmp']);

  return { fromBlob, loadFullImage, extOf, SUPPORTED_EXT };
})();
