<#
PSImgStitcherEngine.ps1

Core image-stitching logic for long/scrolling screenshots - PowerShell port
of stitch_engine.py + imaging.py.

Zero external dependencies: image decode/encode uses .NET's built-in
System.Drawing (GDI+), and all the pixel-crunching (row signatures, overlap
search, feather blending) is implemented in a small block of C# compiled at
runtime via Add-Type, since per-pixel loops in pure PowerShell would be far
too slow for anything but tiny images. No modules, no NuGet, nothing
downloaded - just Windows PowerShell (or PowerShell 7) on Windows.

Same overlap-detection approach as the Python original:
  1. Reduce every row to one brightness value (a "row signature") sampled at
     a handful of columns - turns overlap search into a cheap 1-D compare.
  2. Use that signature to find candidate vertical offsets where the top of
     the next screenshot lines up with the bottom of the previous one.
  3. Confirm/rank every plausible candidate with a real pixel-difference
     check and keep the best (lowest error) one, rejecting ambiguous ties.
#>

# ======================================================== native (C#) core

if (-not ([System.Management.Automation.PSTypeName]'PicoImage').Type) {

    $csSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public class PicoImage
{
    public int Width;
    public int Height;
    public byte[] Data; // flat RGB, row-major, top row first

    public PicoImage(int width, int height, byte[] data)
    {
        Width = width;
        Height = height;
        Data = data;
    }

    public static PicoImage Load(string path)
    {
        using (Bitmap loaded = new Bitmap(path))
        {
            return FromBitmap(loaded);
        }
    }

    public static PicoImage FromBitmap(Bitmap bmp)
    {
        int width = bmp.Width;
        int height = bmp.Height;

        Bitmap src = bmp;
        bool ownsSrc = false;
        if (bmp.PixelFormat != PixelFormat.Format24bppRgb)
        {
            src = new Bitmap(width, height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(src))
            {
                g.DrawImage(bmp, 0, 0, width, height);
            }
            ownsSrc = true;
        }

        byte[] data = new byte[width * height * 3];
        BitmapData bd = src.LockBits(new Rectangle(0, 0, width, height),
            ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int stride = bd.Stride;
            byte[] rowBuf = new byte[Math.Abs(stride)];
            for (int y = 0; y < height; y++)
            {
                IntPtr rowPtr = IntPtr.Add(bd.Scan0, y * stride);
                Marshal.Copy(rowPtr, rowBuf, 0, rowBuf.Length);
                int destOff = y * width * 3;
                for (int x = 0; x < width; x++)
                {
                    int so = x * 3;
                    int dOff = destOff + x * 3;
                    // GDI+ 24bppRgb scanlines are stored as BGR
                    data[dOff] = rowBuf[so + 2];
                    data[dOff + 1] = rowBuf[so + 1];
                    data[dOff + 2] = rowBuf[so];
                }
            }
        }
        finally
        {
            src.UnlockBits(bd);
            if (ownsSrc) src.Dispose();
        }
        return new PicoImage(width, height, data);
    }

    public Bitmap ToBitmap()
    {
        Bitmap bmp = new Bitmap(Math.Max(1, Width), Math.Max(1, Height), PixelFormat.Format24bppRgb);
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
            ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
        try
        {
            int stride = bd.Stride;
            byte[] rowBuf = new byte[stride];
            for (int y = 0; y < Height; y++)
            {
                int srcOff = y * Width * 3;
                for (int x = 0; x < Width; x++)
                {
                    int so = srcOff + x * 3;
                    int dOff = x * 3;
                    rowBuf[dOff] = Data[so + 2];     // B
                    rowBuf[dOff + 1] = Data[so + 1]; // G
                    rowBuf[dOff + 2] = Data[so];     // R
                }
                Marshal.Copy(rowBuf, 0, IntPtr.Add(bd.Scan0, y * stride), stride);
            }
        }
        finally
        {
            bmp.UnlockBits(bd);
        }
        return bmp;
    }

    public void SavePng(string path)
    {
        using (Bitmap bmp = ToBitmap())
        {
            bmp.Save(path, ImageFormat.Png);
        }
    }

    public PicoImage CropRows(int y0, int y1)
    {
        int h = Math.Max(0, y1 - y0);
        int stride = Width * 3;
        byte[] outData = new byte[stride * h];
        if (h > 0)
            Array.Copy(Data, y0 * stride, outData, 0, stride * h);
        return new PicoImage(Width, h, outData);
    }

    public PicoImage ResizedToWidth(int newWidth)
    {
        if (newWidth == Width || Width == 0) return this;
        double scale = (double)newWidth / Width;
        int newHeight = Math.Max(1, (int)Math.Round(Height * scale));

        int[] colMap = new int[newWidth];
        for (int x = 0; x < newWidth; x++)
            colMap[x] = Math.Min(Width - 1, (int)(x / scale)) * 3;

        byte[] outData = new byte[newWidth * newHeight * 3];
        for (int y = 0; y < newHeight; y++)
        {
            int sy = Math.Min(Height - 1, (int)(y / scale));
            int srcRowOff = sy * Width * 3;
            int dstRowOff = y * newWidth * 3;
            for (int x = 0; x < newWidth; x++)
            {
                int so = srcRowOff + colMap[x];
                int dOff = dstRowOff + x * 3;
                outData[dOff] = Data[so];
                outData[dOff + 1] = Data[so + 1];
                outData[dOff + 2] = Data[so + 2];
            }
        }
        return new PicoImage(newWidth, newHeight, outData);
    }

    public static PicoImage VStack(PicoImage[] images)
    {
        int width = 0;
        int totalHeight = 0;
        foreach (PicoImage im in images)
        {
            if (im.Height <= 0) continue;
            width = im.Width;
            totalHeight += im.Height;
        }
        if (totalHeight == 0) return new PicoImage(0, 0, new byte[0]);

        byte[] outData = new byte[width * totalHeight * 3];
        int pos = 0;
        foreach (PicoImage im in images)
        {
            if (im.Height <= 0) continue;
            Array.Copy(im.Data, 0, outData, pos, im.Data.Length);
            pos += im.Data.Length;
        }
        return new PicoImage(width, totalHeight, outData);
    }
}

public struct OverlapResult
{
    public int OverlapPx;
    public double Confidence;
    public double AvgError;

    public OverlapResult(int overlapPx, double confidence, double avgError)
    {
        OverlapPx = overlapPx;
        Confidence = confidence;
        AvgError = avgError;
    }
}

public class StitchCoreConfig
{
    public int RowSamples = 64;
    public int MinOverlapPixels = 15;
    public double MaxAvgError = 6.0;
    public int MaxOverlapSearchPixels = 0;
    public int MaxOutputHeightPixels = 18000;
    public string SortMode = "Name";
    public double MinConfidence = 0.55;
    public int FeatherPixels = 6;
    public double SideMarginPercent = 0.03;
    public double MaxDiffPixelFraction = 0.12;
    public double MaxOverlapFraction = 0.96;
    public double DuplicateFrameMaxAvgError = 0.5;
    public double AmbiguityMinRatio = 2.0;
    public double OverlapSharpnessRatio = 0.4;
}

public static class StitchCore
{
    public static double[] RowSignature(byte[] data, int width, int height, int x0, int x1, int targetSamples)
    {
        int w = Math.Max(1, x1 - x0);
        int step = Math.Max(1, w / targetSamples);
        double[] sig = new double[height];
        for (int y = 0; y < height; y++)
        {
            int rowOff = y * width * 3 + x0 * 3;
            long total = 0;
            int cnt = 0;
            for (int x = 0; x < w; x += step)
            {
                int o = rowOff + x * 3;
                total += data[o] + data[o + 1] + data[o + 2];
                cnt++;
            }
            sig[y] = cnt > 0 ? (double)total / (cnt * 3) : 0.0;
        }
        return sig;
    }

    private static double PStdDev(double[] arr, int start, int end)
    {
        int n = end - start;
        if (n <= 1) return 0.0;
        double mean = 0.0;
        for (int i = start; i < end; i++) mean += arr[i];
        mean /= n;
        double ss = 0.0;
        for (int i = start; i < end; i++)
        {
            double d = arr[i] - mean;
            ss += d * d;
        }
        return Math.Sqrt(ss / n);
    }

    public static int PickTemplateLen(double[] sig, int rowSamples, double minStd, int maxRows)
    {
        int h = sig.Length;
        int end = Math.Min(rowSamples, h);
        while (end < Math.Min(h, maxRows))
        {
            double std = PStdDev(sig, 0, end);
            if (std >= minStd) break;
            end = Math.Min(end + rowSamples, Math.Min(h, maxRows));
        }
        return Math.Max(end, Math.Min(4, h));
    }

    public static double WholeImageDiff(byte[] a, byte[] b, int width, int height, int x0, int x1, int colStep)
    {
        long total = 0;
        long count = 0;
        for (int y = 0; y < height; y++)
        {
            int rowOff = y * width * 3;
            for (int x = x0; x < x1; x += colStep)
            {
                int o = rowOff + x * 3;
                total += Math.Abs(a[o] - b[o]) + Math.Abs(a[o + 1] - b[o + 1]) + Math.Abs(a[o + 2] - b[o + 2]);
                count += 3;
            }
        }
        return count > 0 ? (double)total / count : 999.0;
    }

    public static void VerifyOverlap(byte[] prevData, int prevWidth, byte[] nextData, int nextWidth,
        int x0, int x1, int prevH, int overlapPx, out double avgError, out double diffFraction)
    {
        int w = x1 - x0;
        int colStep = Math.Max(1, w / 150);
        long total = 0;
        long over40 = 0;
        long count = 0;
        for (int r = 0; r < overlapPx; r++)
        {
            int prevRowOff = (prevH - overlapPx + r) * prevWidth * 3;
            int nextRowOff = r * nextWidth * 3;
            for (int x = x0; x < x1; x += colStep)
            {
                int po = prevRowOff + x * 3;
                int no = nextRowOff + x * 3;
                for (int c = 0; c < 3; c++)
                {
                    int d = Math.Abs(prevData[po + c] - nextData[no + c]);
                    total += d;
                    if (d > 40) over40++;
                    count++;
                }
            }
        }
        if (count == 0) { avgError = 999.0; diffFraction = 1.0; return; }
        avgError = (double)total / count;
        diffFraction = (double)over40 / count;
    }

    public static void DetectOverlapAttempt(
        double[] prevSig, double[] nextSig,
        byte[] prevData, int prevWidth, byte[] nextData, int nextWidth,
        int x0, int x1, int rowSamplesTarget, StitchCoreConfig cfg,
        out int overlapPx, out double confidence, out double avgError, out double bestPossibleScore)
    {
        overlapPx = 0;
        confidence = 0.0;
        avgError = 999.0;
        bestPossibleScore = 0.0;

        int prevH = prevSig.Length;
        int nextH = nextSig.Length;

        int templateLen = PickTemplateLen(nextSig, rowSamplesTarget, 4.0, 400);
        if (templateLen < 4) return;

        double[] template = new double[templateLen];
        Array.Copy(nextSig, 0, template, 0, templateLen);

        int searchMax = cfg.MaxOverlapSearchPixels > 0 ? cfg.MaxOverlapSearchPixels : prevH;
        searchMax = Math.Min(searchMax, prevH);
        int searchStart = Math.Max(0, prevH - searchMax);

        if (prevH - searchStart <= templateLen) return;

        int maxAllowedOverlap = (int)(Math.Min(prevH, nextH) * cfg.MaxOverlapFraction);

        List<Tuple<double, int>> candidates = new List<Tuple<double, int>>();
        int maxIdx = prevH - templateLen;
        for (int idx = searchStart; idx <= maxIdx; idx++)
        {
            double sad = 0.0;
            for (int i = 0; i < templateLen; i++)
                sad += Math.Abs(prevSig[idx + i] - template[i]);
            int overlap = prevH - idx;
            if (overlap < cfg.MinOverlapPixels || overlap > nextH) continue;
            if (overlap > maxAllowedOverlap) continue;
            candidates.Add(Tuple.Create(sad, overlap));
        }

        if (candidates.Count == 0) return;

        candidates.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        double bestSad = candidates[0].Item1;
        bestPossibleScore = Math.Max(0.0, 1.0 - (bestSad / templateLen) / 255.0);
        confidence = bestPossibleScore;
        if (bestPossibleScore < cfg.MinConfidence) return;

        int distinctRadius = Math.Max(cfg.MinOverlapPixels, templateLen);
        List<int> checkedOffsets = new List<int>();
        List<Tuple<double, int, double>> evaluated = new List<Tuple<double, int, double>>();

        foreach (Tuple<double, int> cand in candidates)
        {
            int ov = cand.Item2;
            bool tooClose = false;
            foreach (int c in checkedOffsets)
            {
                if (Math.Abs(ov - c) < Math.Max(4, templateLen / 4)) { tooClose = true; break; }
            }
            if (tooClose) continue;
            checkedOffsets.Add(ov);

            double ae, df;
            VerifyOverlap(prevData, prevWidth, nextData, nextWidth, x0, x1, prevH, ov, out ae, out df);
            evaluated.Add(Tuple.Create(ae, ov, df));
            if (checkedOffsets.Count >= 15) break;
        }

        if (evaluated.Count == 0) return;

        evaluated.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        double bestError = evaluated[0].Item1;
        int bestOverlap = evaluated[0].Item2;
        double bestDiffFraction = evaluated[0].Item3;

        double? secondBestError = null;
        for (int i = 1; i < evaluated.Count; i++)
        {
            if (Math.Abs(evaluated[i].Item2 - bestOverlap) >= distinctRadius)
            {
                secondBestError = evaluated[i].Item1;
                break;
            }
        }
        if (secondBestError.HasValue &&
            secondBestError.Value < Math.Max(bestError * cfg.AmbiguityMinRatio, bestError + 2.0))
        {
            return; // ambiguous - refuse to pick, fall back to stacking
        }

        if (bestError <= cfg.MaxAvgError && bestDiffFraction <= cfg.MaxDiffPixelFraction)
        {
            overlapPx = bestOverlap;
            confidence = Math.Max(0.0, 1.0 - bestError / 255.0);
            avgError = bestError;
        }
    }

    public static OverlapResult DetectOverlap(PicoImage prevImg, PicoImage nextImg, StitchCoreConfig cfg)
    {
        int prevW = prevImg.Width;
        int margin = (int)(prevW * cfg.SideMarginPercent);
        int x0 = margin;
        int x1 = Math.Max(margin + 1, prevW - margin);

        double[] prevSig = RowSignature(prevImg.Data, prevImg.Width, prevImg.Height, x0, x1, 64);
        double[] nextSig = RowSignature(nextImg.Data, nextImg.Width, nextImg.Height, x0, x1, 64);

        int cap = Math.Max(cfg.RowSamples, Math.Min(Math.Min(nextImg.Height, prevImg.Height), 400));
        List<int> triedSizes = new List<int>();
        foreach (int s in new int[] { cfg.RowSamples, cfg.RowSamples * 2, cfg.RowSamples * 4 })
        {
            if (s <= cap && !triedSizes.Contains(s)) triedSizes.Add(s);
        }
        triedSizes.Sort();
        if (triedSizes.Count == 0) triedSizes.Add(cap);

        double bestFallbackConf = 0.0;
        for (int attempt = 0; attempt < triedSizes.Count; attempt++)
        {
            int overlapPx; double confidence, avgError, bestSeen;
            DetectOverlapAttempt(prevSig, nextSig, prevImg.Data, prevImg.Width, nextImg.Data, nextImg.Width,
                x0, x1, triedSizes[attempt], cfg, out overlapPx, out confidence, out avgError, out bestSeen);
            if (overlapPx > 0) return new OverlapResult(overlapPx, confidence, avgError);
            if (attempt == 0) bestFallbackConf = bestSeen;
        }
        return new OverlapResult(0, bestFallbackConf, 999.0);
    }

    public static PicoImage FeatherBlend(PicoImage prevImg, PicoImage nextImg, int overlapPx, int featherIn)
    {
        int feather = Math.Max(0, Math.Min(Math.Min(featherIn, overlapPx), nextImg.Height - 1));
        PicoImage cropped = nextImg.CropRows(overlapPx, nextImg.Height);
        if (feather == 0) return cropped;

        int width = prevImg.Width;
        int prevH = prevImg.Height;
        byte[] prevData = prevImg.Data;
        byte[] nextData = nextImg.Data;

        byte[] blended = new byte[width * feather * 3];
        for (int r = 0; r < feather; r++)
        {
            double alpha = feather > 1 ? (double)r / (feather - 1) : 1.0;
            int prevOff = (prevH - feather + r) * width * 3;
            int nextOff = (overlapPx - feather + r) * width * 3;
            int outOff = r * width * 3;
            for (int i = 0; i < width * 3; i++)
            {
                byte pv = prevData[prevOff + i];
                byte nv = nextData[nextOff + i];
                blended[outOff + i] = (byte)(pv * (1 - alpha) + nv * alpha);
            }
        }
        PicoImage blendedImg = new PicoImage(width, feather, blended);
        return PicoImage.VStack(new PicoImage[] { blendedImg, cropped });
    }
}

public class NaturalFileComparer : IComparer<string>
{
    private static readonly Regex NumRe = new Regex(@"(\d+)");

    public int Compare(string a, string b)
    {
        string[] pa = NumRe.Split(System.IO.Path.GetFileName(a));
        string[] pb = NumRe.Split(System.IO.Path.GetFileName(b));
        int len = Math.Min(pa.Length, pb.Length);
        for (int i = 0; i < len; i++)
        {
            string sa = pa[i], sb = pb[i];
            long na, nb;
            bool isNumA = long.TryParse(sa, out na);
            bool isNumB = long.TryParse(sb, out nb);
            int cmp = (isNumA && isNumB)
                ? na.CompareTo(nb)
                : string.Compare(sa, sb, StringComparison.OrdinalIgnoreCase);
            if (cmp != 0) return cmp;
        }
        return pa.Length.CompareTo(pb.Length);
    }
}
'@

    Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition $csSource -Language CSharp
}

# ================================================================ config

$script:StitchConfigDefaults = [ordered]@{
    RowSamples                = 64
    MinOverlapPixels          = 15
    MaxAvgError               = 6.0
    MaxOverlapSearchPixels    = 0
    MaxOutputHeightPixels     = 18000
    SortMode                  = "Name"
    MinConfidence             = 0.55
    FeatherPixels             = 6
    SideMarginPercent         = 0.03
    MaxDiffPixelFraction      = 0.12
    MaxOverlapFraction        = 0.96
    DuplicateFrameMaxAvgError = 0.5
    AmbiguityMinRatio         = 2.0
    OverlapSharpnessRatio     = 0.4
    LastSourceFolder          = ""
    LastOutputFolder          = ""
}

function New-StitchConfig {
    $cfg = [PSCustomObject]::new()
    foreach ($key in $script:StitchConfigDefaults.Keys) {
        $cfg | Add-Member -MemberType NoteProperty -Name $key -Value $script:StitchConfigDefaults[$key]
    }
    return $cfg
}

function Import-StitchConfigFile {
    param([Parameter(Mandatory)][string]$Path)

    $cfg = New-StitchConfig
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in $script:StitchConfigDefaults.Keys) {
                if ($null -ne $json.$key) {
                    $cfg.$key = $json.$key
                }
            }
        }
        catch {
            # malformed config file - fall back to defaults, same as the Python original
        }
    }
    return $cfg
}

function Export-StitchConfigFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Config
    )
    try {
        $Config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
    catch {
        Write-Warning "Could not save config: $_"
    }
}

function ConvertTo-StitchCoreConfig {
    param([Parameter(Mandatory)]$Config)

    $native = New-Object StitchCoreConfig
    $native.RowSamples                = [int]$Config.RowSamples
    $native.MinOverlapPixels          = [int]$Config.MinOverlapPixels
    $native.MaxAvgError               = [double]$Config.MaxAvgError
    $native.MaxOverlapSearchPixels    = [int]$Config.MaxOverlapSearchPixels
    $native.MaxOutputHeightPixels     = [int]$Config.MaxOutputHeightPixels
    $native.SortMode                  = [string]$Config.SortMode
    $native.MinConfidence             = [double]$Config.MinConfidence
    $native.FeatherPixels             = [int]$Config.FeatherPixels
    $native.SideMarginPercent         = [double]$Config.SideMarginPercent
    $native.MaxDiffPixelFraction      = [double]$Config.MaxDiffPixelFraction
    $native.MaxOverlapFraction        = [double]$Config.MaxOverlapFraction
    $native.DuplicateFrameMaxAvgError = [double]$Config.DuplicateFrameMaxAvgError
    $native.AmbiguityMinRatio         = [double]$Config.AmbiguityMinRatio
    $native.OverlapSharpnessRatio     = [double]$Config.OverlapSharpnessRatio
    return $native
}

# =========================================================== file listing

function Get-StitchImageList {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [string]$SortMode = "Name"
    )

    $exts = @(".png", ".bmp")
    $items = Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLowerInvariant() }

    if ($SortMode -eq "Date") {
        $items = $items | Sort-Object LastWriteTime
        return @($items | ForEach-Object { $_.FullName })
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $items) { $paths.Add($it.FullName) }
    $comparer = New-Object NaturalFileComparer
    $paths.Sort($comparer)
    return @($paths)
}

# ============================================================ main loop

function Invoke-StitchFolder {
    <#
    Stitches every screenshot in SourceFolder into one or more long PNGs in
    OutputFolder, splitting whenever MaxOutputHeightPixels would be
    exceeded. Returns the list of output file paths written.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)]$Config,
        [scriptblock]$Log = { param($msg) },
        [scriptblock]$StopFlag = { $false }
    )

    function _log([string]$msg) { & $Log $msg }

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $files = Get-StitchImageList -Folder $SourceFolder -SortMode $Config.SortMode
    if ($files.Count -eq 0) {
        _log "No supported images found in source folder (PNG or BMP only)."
        return @()
    }

    _log "Found $($files.Count) images. Sort mode: $($Config.SortMode)"

    $nativeCfg = ConvertTo-StitchCoreConfig -Config $Config

    $outputs = [System.Collections.Generic.List[string]]::new()
    $canvas = $null
    $lastRawHeight = 0
    $lastRawImg = $null
    $partIndex = 1

    for ($i = 0; $i -lt $files.Count; $i++) {
        if (& $StopFlag) {
            _log "Stopped by user."
            break
        }

        $path = $files[$i]
        $name = [System.IO.Path]::GetFileName($path)
        $img = [PicoImage]::Load($path)

        if ($null -eq $canvas) {
            $canvas = $img
            $lastRawHeight = $img.Height
            $lastRawImg = $img
            _log "[$($i + 1)/$($files.Count)] $name -> start of new sheet"
            continue
        }

        if ($img.Width -ne $canvas.Width) {
            $img = $img.ResizedToWidth($canvas.Width)
        }

        # Accidental duplicate capture: skip a screenshot that is basically
        # pixel-identical to the one before it.
        if ($null -ne $lastRawImg -and $img.Width -eq $lastRawImg.Width -and $img.Height -eq $lastRawImg.Height) {
            $margin = [int]($img.Width * $Config.SideMarginPercent)
            $x0 = $margin
            $x1 = [Math]::Max($margin + 1, $img.Width - $margin)
            $colStep = [Math]::Max(1, [int](($x1 - $x0) / 150))
            $dupError = [StitchCore]::WholeImageDiff($img.Data, $lastRawImg.Data, $img.Width, $img.Height, $x0, $x1, $colStep)
            if ($dupError -le [double]$Config.DuplicateFrameMaxAvgError) {
                _log "[$($i + 1)/$($files.Count)] $name -> duplicate of previous screenshot, skipped"
                continue
            }
        }

        $searchBound = $lastRawHeight
        if ([int]$Config.MaxOverlapSearchPixels -gt 0) {
            $searchBound = [Math]::Min($searchBound, [int]$Config.MaxOverlapSearchPixels)
        }
        $searchBound = [Math]::Min($searchBound, $canvas.Height)
        $prevSearchSlice = $canvas.CropRows($canvas.Height - $searchBound, $canvas.Height)

        $result = [StitchCore]::DetectOverlap($prevSearchSlice, $img, $nativeCfg)

        if ($result.OverlapPx -gt 0) {
            $piece = [StitchCore]::FeatherBlend($prevSearchSlice, $img, $result.OverlapPx, [int]$Config.FeatherPixels)
            $trim = [Math]::Min([Math]::Min([int]$Config.FeatherPixels, $result.OverlapPx), $canvas.Height)
            $baseImg = if ($trim -gt 0) { $canvas.CropRows(0, $canvas.Height - $trim) } else { $canvas }
            $newHeight = $baseImg.Height + $piece.Height
            _log ("[{0}/{1}] {2} -> overlap {3}px (confidence {4:F2}, avg diff {5:F1})" -f `
                ($i + 1), $files.Count, $name, $result.OverlapPx, $result.Confidence, $result.AvgError)
        }
        else {
            $piece = $img
            $baseImg = $canvas
            $newHeight = $baseImg.Height + $piece.Height
            _log "[$($i + 1)/$($files.Count)] $name -> no overlap detected, stacked directly"
        }

        if ($newHeight -gt [int]$Config.MaxOutputHeightPixels -and $canvas.Height -gt 0) {
            $outPath = Join-Path $OutputFolder ("Stitched_{0:D3}.png" -f $partIndex)
            $canvas.SavePng($outPath)
            $outputs.Add($outPath)
            _log "Saved $outPath  ($($canvas.Width)x$($canvas.Height)px)"
            $partIndex++
            $canvas = $img
            $lastRawHeight = $img.Height
            $lastRawImg = $img
            continue
        }

        $canvas = [PicoImage]::VStack(@($baseImg, $piece))
        $lastRawHeight = $img.Height
        $lastRawImg = $img
    }

    if ($null -ne $canvas) {
        $outPath = Join-Path $OutputFolder ("Stitched_{0:D3}.png" -f $partIndex)
        $canvas.SavePng($outPath)
        $outputs.Add($outPath)
        _log "Saved $outPath  ($($canvas.Width)x$($canvas.Height)px)"
    }

    _log "Done. Wrote $($outputs.Count) file(s)."
    return @($outputs)
}
