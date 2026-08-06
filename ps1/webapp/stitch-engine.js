// Direct JS port of PSImgStitcherEngine.ps1's PicoImage / StitchCore C#
// core. Same algorithm, same defaults, same field names in the config
// object (so psimgstitcher_config.json loads here unchanged):
//   1. Reduce every row to one brightness value (a "row signature")
//      sampled at a handful of columns - turns overlap search into a
//      cheap 1-D compare.
//   2. Use that signature to find candidate vertical offsets where the
//      top of the next screenshot lines up with the bottom of the
//      previous one.
//   3. Confirm/rank every plausible candidate with a real pixel-difference
//      check and keep the best (lowest error) one, rejecting ambiguous ties.
//
// "Image" shape used throughout: { width, height, data: Uint8Array } where
// data is flat RGB, row-major, top row first - the same layout PicoImage
// used internally.
window.ShotStitcher = window.ShotStitcher || {};

window.ShotStitcher.Engine = (function () {

  const DEFAULT_CONFIG = {
    RowSamples: 64,
    MinOverlapPixels: 15,
    MaxAvgError: 6.0,
    MaxOverlapSearchPixels: 0,
    MaxOutputHeightPixels: 18000,
    SortMode: 'Name',
    MinConfidence: 0.55,
    FeatherPixels: 6,
    SideMarginPercent: 0.03,
    MaxDiffPixelFraction: 0.12,
    MaxOverlapFraction: 0.96,
    DuplicateFrameMaxAvgError: 0.5,
    AmbiguityMinRatio: 2.0,
    OverlapSharpnessRatio: 0.4,
  };

  // ---------------------------------------------------------- image utils

  function fromImageData(imageData) {
    const { width, height, data: rgba } = imageData;
    const data = new Uint8Array(width * height * 3);
    for (let i = 0, j = 0; j < data.length; i += 4, j += 3) {
      data[j] = rgba[i]; data[j + 1] = rgba[i + 1]; data[j + 2] = rgba[i + 2];
    }
    return { width, height, data };
  }

  function toImageData(img) {
    const rgba = new Uint8ClampedArray(img.width * img.height * 4);
    for (let i = 0, j = 0; j < img.data.length; i += 4, j += 3) {
      rgba[i] = img.data[j]; rgba[i + 1] = img.data[j + 1]; rgba[i + 2] = img.data[j + 2]; rgba[i + 3] = 255;
    }
    return new ImageData(rgba, img.width, img.height);
  }

  function cropRows(img, y0, y1) {
    const h = Math.max(0, y1 - y0);
    const stride = img.width * 3;
    const out = new Uint8Array(stride * h);
    if (h > 0) out.set(img.data.subarray(y0 * stride, y0 * stride + stride * h));
    return { width: img.width, height: h, data: out };
  }

  function resizedToWidth(img, newWidth) {
    if (newWidth === img.width || img.width === 0) return img;
    const scale = newWidth / img.width;
    const newHeight = Math.max(1, Math.round(img.height * scale));
    const colMap = new Int32Array(newWidth);
    for (let x = 0; x < newWidth; x++) colMap[x] = Math.min(img.width - 1, Math.floor(x / scale)) * 3;
    const out = new Uint8Array(newWidth * newHeight * 3);
    for (let y = 0; y < newHeight; y++) {
      const sy = Math.min(img.height - 1, Math.floor(y / scale));
      const srcRowOff = sy * img.width * 3;
      const dstRowOff = y * newWidth * 3;
      for (let x = 0; x < newWidth; x++) {
        const so = srcRowOff + colMap[x];
        const dOff = dstRowOff + x * 3;
        out[dOff] = img.data[so]; out[dOff + 1] = img.data[so + 1]; out[dOff + 2] = img.data[so + 2];
      }
    }
    return { width: newWidth, height: newHeight, data: out };
  }

  function vstack(images) {
    let width = 0, totalHeight = 0;
    images.forEach(im => { if (im.height > 0) { width = im.width; totalHeight += im.height; } });
    if (totalHeight === 0) return { width: 0, height: 0, data: new Uint8Array(0) };
    const out = new Uint8Array(width * totalHeight * 3);
    let pos = 0;
    images.forEach(im => { if (im.height > 0) { out.set(im.data, pos); pos += im.data.length; } });
    return { width, height: totalHeight, data: out };
  }

  // -------------------------------------------------------- overlap search

  function rowSignature(data, width, height, x0, x1, targetSamples) {
    const w = Math.max(1, x1 - x0);
    const step = Math.max(1, Math.floor(w / targetSamples));
    const sig = new Float64Array(height);
    for (let y = 0; y < height; y++) {
      const rowOff = y * width * 3 + x0 * 3;
      let total = 0, cnt = 0;
      for (let x = 0; x < w; x += step) {
        const o = rowOff + x * 3;
        total += data[o] + data[o + 1] + data[o + 2];
        cnt++;
      }
      sig[y] = cnt > 0 ? total / (cnt * 3) : 0.0;
    }
    return sig;
  }

  function pStdDev(arr, start, end) {
    const n = end - start;
    if (n <= 1) return 0.0;
    let mean = 0.0;
    for (let i = start; i < end; i++) mean += arr[i];
    mean /= n;
    let ss = 0.0;
    for (let i = start; i < end; i++) { const d = arr[i] - mean; ss += d * d; }
    return Math.sqrt(ss / n);
  }

  function pickTemplateLen(sig, rowSamples, minStd, maxRows) {
    const h = sig.length;
    let end = Math.min(rowSamples, h);
    while (end < Math.min(h, maxRows)) {
      const std = pStdDev(sig, 0, end);
      if (std >= minStd) break;
      end = Math.min(end + rowSamples, Math.min(h, maxRows));
    }
    return Math.max(end, Math.min(4, h));
  }

  function wholeImageDiff(a, b, width, height, x0, x1, colStep) {
    let total = 0, count = 0;
    for (let y = 0; y < height; y++) {
      const rowOff = y * width * 3;
      for (let x = x0; x < x1; x += colStep) {
        const o = rowOff + x * 3;
        total += Math.abs(a[o] - b[o]) + Math.abs(a[o + 1] - b[o + 1]) + Math.abs(a[o + 2] - b[o + 2]);
        count += 3;
      }
    }
    return count > 0 ? total / count : 999.0;
  }

  function verifyOverlap(prevData, prevWidth, nextData, nextWidth, x0, x1, prevH, overlapPx) {
    const w = x1 - x0;
    const colStep = Math.max(1, Math.floor(w / 150));
    let total = 0, over40 = 0, count = 0;
    for (let r = 0; r < overlapPx; r++) {
      const prevRowOff = (prevH - overlapPx + r) * prevWidth * 3;
      const nextRowOff = r * nextWidth * 3;
      for (let x = x0; x < x1; x += colStep) {
        const po = prevRowOff + x * 3, no = nextRowOff + x * 3;
        for (let c = 0; c < 3; c++) {
          const d = Math.abs(prevData[po + c] - nextData[no + c]);
          total += d;
          if (d > 40) over40++;
          count++;
        }
      }
    }
    if (count === 0) return { avgError: 999.0, diffFraction: 1.0 };
    return { avgError: total / count, diffFraction: over40 / count };
  }

  function detectOverlapAttempt(prevSig, nextSig, prevData, prevWidth, nextData, nextWidth, x0, x1, rowSamplesTarget, cfg) {
    let overlapPx = 0, confidence = 0.0, avgError = 999.0, bestPossibleScore = 0.0;
    const prevH = prevSig.length, nextH = nextSig.length;

    const templateLen = pickTemplateLen(nextSig, rowSamplesTarget, 4.0, 400);
    if (templateLen < 4) return { overlapPx, confidence, avgError, bestPossibleScore };

    const template = nextSig.subarray(0, templateLen);
    let searchMax = cfg.MaxOverlapSearchPixels > 0 ? cfg.MaxOverlapSearchPixels : prevH;
    searchMax = Math.min(searchMax, prevH);
    const searchStart = Math.max(0, prevH - searchMax);
    if (prevH - searchStart <= templateLen) return { overlapPx, confidence, avgError, bestPossibleScore };

    const maxAllowedOverlap = Math.floor(Math.min(prevH, nextH) * cfg.MaxOverlapFraction);

    const candidates = []; // [sad, overlap]
    const maxIdx = prevH - templateLen;
    for (let idx = searchStart; idx <= maxIdx; idx++) {
      let sad = 0;
      for (let i = 0; i < templateLen; i++) sad += Math.abs(prevSig[idx + i] - template[i]);
      const overlap = prevH - idx;
      if (overlap < cfg.MinOverlapPixels || overlap > nextH) continue;
      if (overlap > maxAllowedOverlap) continue;
      candidates.push([sad, overlap]);
    }
    if (candidates.length === 0) return { overlapPx, confidence, avgError, bestPossibleScore };

    candidates.sort((a, b) => a[0] - b[0]);
    const bestSad = candidates[0][0];
    bestPossibleScore = Math.max(0.0, 1.0 - (bestSad / templateLen) / 255.0);
    confidence = bestPossibleScore;
    if (bestPossibleScore < cfg.MinConfidence) return { overlapPx, confidence, avgError, bestPossibleScore };

    const distinctRadius = Math.max(cfg.MinOverlapPixels, templateLen);
    const checkedOffsets = [];
    const evaluated = []; // [avgError, overlap, diffFraction]

    for (const [, ov] of candidates) {
      let tooClose = false;
      for (const c of checkedOffsets) {
        if (Math.abs(ov - c) < Math.max(4, Math.floor(templateLen / 4))) { tooClose = true; break; }
      }
      if (tooClose) continue;
      checkedOffsets.push(ov);
      const { avgError: ae, diffFraction: df } = verifyOverlap(prevData, prevWidth, nextData, nextWidth, x0, x1, prevH, ov);
      evaluated.push([ae, ov, df]);
      if (checkedOffsets.length >= 15) break;
    }
    if (evaluated.length === 0) return { overlapPx, confidence, avgError, bestPossibleScore };

    evaluated.sort((a, b) => a[0] - b[0]);
    const bestError = evaluated[0][0], bestOverlap = evaluated[0][1], bestDiffFraction = evaluated[0][2];

    let secondBestError = null;
    for (let i = 1; i < evaluated.length; i++) {
      if (Math.abs(evaluated[i][1] - bestOverlap) >= distinctRadius) { secondBestError = evaluated[i][0]; break; }
    }
    if (secondBestError !== null && secondBestError < Math.max(bestError * cfg.AmbiguityMinRatio, bestError + 2.0)) {
      return { overlapPx, confidence, avgError, bestPossibleScore }; // ambiguous - refuse, fall back to stacking
    }

    if (bestError <= cfg.MaxAvgError && bestDiffFraction <= cfg.MaxDiffPixelFraction) {
      overlapPx = bestOverlap;
      confidence = Math.max(0.0, 1.0 - bestError / 255.0);
      avgError = bestError;
    }
    return { overlapPx, confidence, avgError, bestPossibleScore };
  }

  function detectOverlap(prevImg, nextImg, cfg) {
    const prevW = prevImg.width;
    const margin = Math.floor(prevW * cfg.SideMarginPercent);
    const x0 = margin;
    const x1 = Math.max(margin + 1, prevW - margin);

    const prevSig = rowSignature(prevImg.data, prevImg.width, prevImg.height, x0, x1, 64);
    const nextSig = rowSignature(nextImg.data, nextImg.width, nextImg.height, x0, x1, 64);

    const cap = Math.max(cfg.RowSamples, Math.min(Math.min(nextImg.height, prevImg.height), 400));
    let triedSizes = [];
    [cfg.RowSamples, cfg.RowSamples * 2, cfg.RowSamples * 4].forEach(s => {
      if (s <= cap && !triedSizes.includes(s)) triedSizes.push(s);
    });
    triedSizes.sort((a, b) => a - b);
    if (triedSizes.length === 0) triedSizes.push(cap);

    let bestFallbackConf = 0.0;
    for (let attempt = 0; attempt < triedSizes.length; attempt++) {
      const r = detectOverlapAttempt(prevSig, nextSig, prevImg.data, prevImg.width, nextImg.data, nextImg.width, x0, x1, triedSizes[attempt], cfg);
      if (r.overlapPx > 0) return { overlapPx: r.overlapPx, confidence: r.confidence, avgError: r.avgError };
      if (attempt === 0) bestFallbackConf = r.bestPossibleScore;
    }
    return { overlapPx: 0, confidence: bestFallbackConf, avgError: 999.0 };
  }

  function featherBlend(prevImg, nextImg, overlapPx, featherIn) {
    const feather = Math.max(0, Math.min(Math.min(featherIn, overlapPx), nextImg.height - 1));
    const cropped = cropRows(nextImg, overlapPx, nextImg.height);
    if (feather === 0) return cropped;

    const width = prevImg.width, prevH = prevImg.height;
    const prevData = prevImg.data, nextData = nextImg.data;
    const blended = new Uint8Array(width * feather * 3);
    for (let r = 0; r < feather; r++) {
      const alpha = feather > 1 ? r / (feather - 1) : 1.0;
      const prevOff = (prevH - feather + r) * width * 3;
      const nextOff = (overlapPx - feather + r) * width * 3;
      const outOff = r * width * 3;
      for (let i = 0; i < width * 3; i++) {
        const pv = prevData[prevOff + i], nv = nextData[nextOff + i];
        blended[outOff + i] = Math.round(pv * (1 - alpha) + nv * alpha);
      }
    }
    return vstack([{ width, height: feather, data: blended }, cropped]);
  }

  // Same natural (numeric-aware) filename ordering as NaturalFileComparer.
  function naturalCompare(a, b) {
    const re = /(\d+)/;
    const pa = a.split(re), pb = b.split(re);
    const len = Math.min(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const sa = pa[i], sb = pb[i];
      const na = Number(sa), nb = Number(sb);
      const isNumA = sa !== '' && !Number.isNaN(na);
      const isNumB = sb !== '' && !Number.isNaN(nb);
      const cmp = (isNumA && isNumB) ? na - nb : sa.localeCompare(sb, undefined, { sensitivity: 'base' });
      if (cmp !== 0) return cmp;
    }
    return pa.length - pb.length;
  }

  // ------------------------------------------------------------ main loop

  // entries: ordered array of { name, img } or { name, getImage } where img
  // is the {width,height,data} shape above and getImage() returns a Promise
  // of one - decoded on demand, one at a time, so a long session doesn't
  // need every screenshot's full-resolution pixels in memory at once. Only
  // the entries the caller has kept/ordered should be passed in - that's
  // the review/discard/reorder step, done in app.js before calling this.
  async function stitchAll(entries, config, onStatus) {
    onStatus = onStatus || function () {};
    const cfg = Object.assign({}, DEFAULT_CONFIG, config || {});
    const sheets = [];
    let canvas = null, lastRawHeight = 0, lastRawImg = null;

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      let img = entry.img || await entry.getImage();
      await new Promise(r => setTimeout(r, 0)); // yield to keep the UI responsive

      if (canvas === null) {
        canvas = img; lastRawHeight = img.height; lastRawImg = img;
        onStatus(`[${i + 1}/${entries.length}] ${entry.name} -> start of new sheet`);
        continue;
      }

      if (img.width !== canvas.width) img = resizedToWidth(img, canvas.width);

      if (lastRawImg && img.width === lastRawImg.width && img.height === lastRawImg.height) {
        const margin = Math.floor(img.width * cfg.SideMarginPercent);
        const x0 = margin, x1 = Math.max(margin + 1, img.width - margin);
        const colStep = Math.max(1, Math.floor((x1 - x0) / 150));
        const dupError = wholeImageDiff(img.data, lastRawImg.data, img.width, img.height, x0, x1, colStep);
        if (dupError <= cfg.DuplicateFrameMaxAvgError) {
          onStatus(`[${i + 1}/${entries.length}] ${entry.name} -> duplicate of previous screenshot, skipped`);
          continue;
        }
      }

      let searchBound = lastRawHeight;
      if (cfg.MaxOverlapSearchPixels > 0) searchBound = Math.min(searchBound, cfg.MaxOverlapSearchPixels);
      searchBound = Math.min(searchBound, canvas.height);
      const prevSearchSlice = cropRows(canvas, canvas.height - searchBound, canvas.height);

      const result = detectOverlap(prevSearchSlice, img, cfg);

      let piece, baseImg, newHeight;
      if (result.overlapPx > 0) {
        piece = featherBlend(prevSearchSlice, img, result.overlapPx, cfg.FeatherPixels);
        const trim = Math.min(Math.min(cfg.FeatherPixels, result.overlapPx), canvas.height);
        baseImg = trim > 0 ? cropRows(canvas, 0, canvas.height - trim) : canvas;
        newHeight = baseImg.height + piece.height;
        onStatus(`[${i + 1}/${entries.length}] ${entry.name} -> overlap ${result.overlapPx}px (confidence ${result.confidence.toFixed(2)}, avg diff ${result.avgError.toFixed(1)})`);
      } else {
        piece = img; baseImg = canvas; newHeight = baseImg.height + piece.height;
        onStatus(`[${i + 1}/${entries.length}] ${entry.name} -> no overlap detected, stacked directly`);
      }

      if (newHeight > cfg.MaxOutputHeightPixels && canvas.height > 0) {
        sheets.push(canvas);
        onStatus(`Sheet complete (${canvas.width}x${canvas.height}px)`);
        canvas = img; lastRawHeight = img.height; lastRawImg = img;
        continue;
      }

      canvas = vstack([baseImg, piece]);
      lastRawHeight = img.height; lastRawImg = img;
    }

    if (canvas !== null) {
      sheets.push(canvas);
      onStatus(`Sheet complete (${canvas.width}x${canvas.height}px)`);
    }
    onStatus(`Done. Produced ${sheets.length} sheet(s).`);
    return sheets;
  }

  return { DEFAULT_CONFIG, fromImageData, toImageData, cropRows, resizedToWidth, vstack, naturalCompare, stitchAll };
})();
