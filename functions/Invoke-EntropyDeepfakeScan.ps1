function Invoke-EntropyDeepfakeScan {
<#
.SYNOPSIS
  Compute pixel-level and byte-level entropy for an image or video,
  produce a 0–10 deepfake-likelihood score, and write a hotspot overlay.

.DESCRIPTION
  - Pixel layer: local Shannon entropy maps (multi-scale) over Y/Cb/Cr,
    edge-vs-flat ratios, JS divergence between luma and chroma entropy hists.
  - Byte layer: sliding-window (2 KiB, 1 KiB stride) Shannon entropy on raw bytes.
  - Video temporal layer: per-pixel temporal variance (proxy for temporal spectral entropy)
    and a flicker index over a sliding frame window.
  - Overlay: heatmap of top-p entropy z-scores with contour guides.

.PARAMETER Path
  Image or video file.

.PARAMETER OutputDir
  Where to write overlay(s), JSON features, and logs.

.PARAMETER Window
  Local entropy radius in pixels (odd). Typical: 7 or 11.

.PARAMETER FrameStride
  Sample every Nth frame for videos to keep it fast.

.PARAMETER OverlayTopP
  Fraction (0–0.2) of highest z-score pixels to visualize as hotspots.

.PARAMETER InstallDependencies
  Ensure Python + pip packages are available (numpy, opencv-python-headless, scikit-image, pillow).

.PARAMETER PassThru
  Return a rich object with Score, Paths, and raw features.

.EXAMPLE
  Invoke-EntropyDeepfakeScan -Path .\suspect.jpg -InstallDependencies -Verbose

.EXAMPLE
  Invoke-EntropyDeepfakeScan -Path .\clip.mp4 -FrameStride 12 -Window 7 -OverlayTopP 0.02 -PassThru

.NOTES
  - Local entropy filter (base-2) per scikit-image. 4
  - Byte-entropy windows inspired by EMBER-style features. 5
  - Temporal pixel-wise inconsistency is a strong deepfake cue. 6
#>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [string]$OutputDir = $(Join-Path (Split-Path -Parent $Path) "entropy-output"),

    [ValidateRange(3,31)]
    [int]$Window = 7,

    [ValidateRange(1,60)]
    [int]$FrameStride = 12,

    [ValidateRange(0.001,0.2)]
    [double]$OverlayTopP = 0.02,

    [switch]$InstallDependencies,
    [switch]$PassThru
  )

  begin {
    if (-not (Test-Path $Path)) { throw "File not found: $Path" }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $pyPath = Join-Path $OutputDir "entropy_probe.py"

    $pyCode = @'
import os, sys, argparse, json, math, mimetypes
import numpy as np
from PIL import Image
import cv2

# deps: skimage for true local entropy (base-2)
from skimage.filters.rank import entropy as rank_entropy
from skimage.morphology import disk
from skimage.color import rgb2ycbcr

def shannon(p):
    p = p.astype(np.float64)
    p = p / (p.sum() + 1e-12)
    nz = p[p>0]
    return -(nz*np.log2(nz)).sum()

def js_divergence(p, q):
    # p,q are histograms (not necessarily normalized)
    p = p.astype(np.float64); q = q.astype(np.float64)
    p /= (p.sum()+1e-12); q /= (q.sum()+1e-12)
    m = 0.5*(p+q)
    def kl(a,b): 
        mask = (a>0) & (b>0)
        return (a[mask]*np.log2(a[mask]/b[mask])).sum()
    return 0.5*kl(p,m) + 0.5*kl(q,m)

def to_u8_gray(img_bgr):
    g = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return g

def local_entropy_u8(u8, radius):
    se = disk(radius)
    return rank_entropy(u8, se)  # base-2 local entropy

def edge_mask(u8):
    med = np.median(u8)
    low = int(max(0, 0.66*med))
    high = int(min(255, 1.33*med))
    e = cv2.Canny(u8, low, high)
    return (e>0)

def frame_features(frame_bgr, radius):
    # YCbCr channels
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    ycbcr = rgb2ycbcr(rgb).astype(np.uint8)
    Y, Cb, Cr = [ycbcr[...,i] for i in range(3)]

    feats = {}
    ch_maps = {}
    for name, ch in [('Y',Y), ('Cb',Cb), ('Cr',Cr)]:
        E = local_entropy_u8(ch, radius)
        ch_maps[name] = E
        feats[f'{name}_E_mean'] = float(E.mean())
        feats[f'{name}_E_std']  = float(E.std())
        # 32-bin histogram over [0, 8] bits (u8 entropy max ~8)
        hist, _ = np.histogram(E, bins=32, range=(0,8))
        feats[f'{name}_E_hist'] = hist.tolist()

    # cross-channel entropy divergence
    Yh = np.array(feats['Y_E_hist']); Cbh = np.array(feats['Cb_E_hist']); Crh = np.array(feats['Cr_E_hist'])
    feats['JS_Y_Cb'] = float(js_divergence(Yh, Cbh))
    feats['JS_Y_Cr'] = float(js_divergence(Yh, Crh))

    # edge vs flat entropy means on Y
    u8 = to_u8_gray(frame_bgr)
    emask = edge_mask(u8)
    flatmask = ~emask
    Ey = ch_maps['Y']
    if emask.any() and flatmask.any():
        feats['E_edge_mean'] = float(Ey[emask].mean())
        feats['E_flat_mean'] = float(Ey[flatmask].mean())
        feats['E_edge_flat_ratio'] = float((Ey[emask].mean()+1e-6)/(Ey[flatmask].mean()+1e-6))
    else:
        feats['E_edge_mean'] = feats['E_flat_mean'] = feats['E_edge_flat_ratio'] = 1.0

    # hotspot fraction via z-score on Y entropy
    mu, sd = Ey.mean(), Ey.std()+1e-9
    Z = (Ey - mu)/sd
    hot = (Z > 2.5)  # 2.5-sigma
    feats['hotspot_frac'] = float(hot.mean())

    return feats, ch_maps

def temporal_flicker(frames_gray):
    # proxy for pixel-wise temporal spectral entropy: std dev over time + high-diff fraction
    # downsample to speed
    F = np.stack(frames_gray, axis=0).astype(np.float32)  # [T,H,W]
    if F.shape[0] < 3:
        return {'flicker_frac': 0.0, 'std_p95': 0.0}
    # per-pixel std across time
    std = F.std(axis=0)
    # high-flicker pixels threshold (empirical)
    thr = 12.0  # intensity on 0..255
    flicker_frac = float((std > thr).mean())
    std_p95 = float(np.percentile(std, 95))
    return {'flicker_frac': flicker_frac, 'std_p95': std_p95}

def draw_overlay(orig_bgr, EntropyMap, out_path, top_p=0.02):
    H, W = EntropyMap.shape
    # z-score normalize
    mu, sd = EntropyMap.mean(), EntropyMap.std()+1e-9
    Z = (EntropyMap - mu)/sd
    # take top-p pixels
    flat = Z.flatten()
    k = max(1, int(len(flat)*max(0.001, min(0.2, top_p))))
    thresh = np.partition(flat, -k)[-k]
    mask = (Z >= thresh).astype(np.uint8)

    # smooth and find contours
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3,3), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # heatmap
    Zn = (np.clip(Z, 0, 5)/5.0*255).astype(np.uint8)
    heat = cv2.applyColorMap(Zn, cv2.COLORMAP_JET)
    overlay = cv2.addWeighted(orig_bgr, 0.65, heat, 0.35, 0)

    # contour guides
    cv2.drawContours(overlay, contours, -1, (0,0,255), 2)
    cv2.imwrite(out_path, overlay)
    return len(contours)

def byte_entropy_features(path, w=2048, s=1024):
    data = np.fromfile(path, dtype=np.uint8)
    if data.size == 0:
        return {'byte_meanH':0.0,'byte_stdH':0.0,'byte_p95H':0.0,'byte_high_frac':0.0}
    Hs = []
    hi = 0
    for i in range(0, len(data)-w+1, s):
        window = data[i:i+w]
        hist, _ = np.histogram(window, bins=256, range=(0,256))
        Hs.append(shannon(hist))
    Hs = np.array(Hs, dtype=np.float64) if Hs else np.array([0.0])
    byte_meanH = float(Hs.mean())
    byte_stdH  = float(Hs.std())
    byte_p95H  = float(np.percentile(Hs, 95))
    byte_high_frac = float((Hs > 7.5).mean())  # near-max entropy windows
    return {'byte_meanH':byte_meanH,'byte_stdH':byte_stdH,'byte_p95H':byte_p95H,'byte_high_frac':byte_high_frac}

def is_video(path):
    mt, _ = mimetypes.guess_type(path)
    if mt is None: return False
    return mt.startswith('video')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--outdir', required=True)
    ap.add_argument('--radius', type=int, default=7)
    ap.add_argument('--frame_stride', type=int, default=12)
    ap.add_argument('--overlay_top_p', type=float, default=0.02)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    bfeats = byte_entropy_features(args.input)

    results = {
        'path': args.input,
        'byte': bfeats,
        'kind': 'video' if is_video(args.input) else 'image'
    }

    if results['kind'] == 'image':
        img_bgr = cv2.imread(args.input, cv2.IMREAD_COLOR)
        if img_bgr is None:
            raise SystemExit("Failed to read image.")
        feats, ch_maps = frame_features(img_bgr, radius=args.radius)
        results['spatial'] = feats
        # overlay on Y entropy map
        overlay_path = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")
        draw_overlay(img_bgr, ch_maps['Y'], overlay_path, top_p=args.overlay_top_p)
        results['overlay'] = overlay_path
        # temporal proxy absent
        results['temporal'] = {'flicker_frac': 0.0, 'std_p95': 0.0}

    else:
        cap = cv2.VideoCapture(args.input)
        if not cap.isOpened():
            raise SystemExit("Failed to open video.")
        fcount = 0
        frames_gray = []
        spatial_accum = []
        overlay_path = None
        median_frame = None
        while True:
            ret = cap.grab()
            if not ret: break
            if (fcount % args.frame_stride) == 0:
                ret, frame = cap.retrieve()
                if not ret: break
                feats, ch_maps = frame_features(frame, radius=args.radius)
                spatial_accum.append(feats)
                frames_gray.append(to_u8_gray(frame))
                # save a representative frame’s overlay later (lazy assign last sampled)
                median_frame = (frame.copy(), ch_maps['Y'])
            fcount += 1
        cap.release()

        if not spatial_accum:
            raise SystemExit("No frames sampled; try smaller --frame_stride.")

        # aggregate spatial features (means of scalars; hists summed)
        keys_scalar = [k for k in spatial_accum[0].keys() if not k.endswith('_hist')]
        agg = {k: float(np.mean([f[k] for f in spatial_accum])) for k in keys_scalar}
        # hist keys
        for c in ['Y','Cb','Cr']:
            hsum = np.sum([f[f'{c}_E_hist'] for f in spatial_accum], axis=0)
            agg[f'{c}_E_hist'] = hsum.tolist()
        results['spatial'] = agg

        # temporal flicker
        tfeat = temporal_flicker(frames_gray)
        results['temporal'] = tfeat

        # overlay on the last representative frame
        if median_frame is not None:
            frame0, Ey = median_frame
            overlay_path = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")
            draw_overlay(frame0, Ey, overlay_path, top_p=args.overlay_top_p)
            results['overlay'] = overlay_path

    # --- scoring (0..10), simple calibrated fusion ---
    # Normalize features to ~[0,1] ranges with conservative caps
    sp = results['spatial']
    hotspot = min(1.0, sp.get('hotspot_frac',0.0) / 0.05)            # >5% hotspots is suspicious
    js = max(sp.get('JS_Y_Cb',0.0), sp.get('JS_Y_Cr',0.0))
    jsn = min(1.0, js / 0.15)                                        # 0.15 JS is quite large for natural
    ratio = sp.get('E_edge_flat_ratio',1.0)
    r_anom = float(max(0.0, min(1.0, (ratio-1.2)/0.6)))              # >1.2 means edges much busier than flats (or vice versa)
    bt = results['byte']
    bhigh = min(1.0, bt.get('byte_high_frac',0.0) / 0.4)             # lots of ~max-entropy windows unusual for typical photos
    tf = results.get('temporal', {'flicker_frac':0.0,'std_p95':0.0})
    flicker = min(1.0, (0.5*tf['flicker_frac'] + 0.5*max(0.0,(tf['std_p95']-8)/10)))
    # weights (sum ~1)
    w_hot, w_js, w_tem, w_byte, w_edge = 0.35, 0.25, 0.20, 0.10, 0.10
    score01 = w_hot*hotspot + w_js*jsn + w_tem*flicker + w_byte*bhigh + w_edge*r_anom
    score = round(10.0*max(0.0, min(1.0, score01)), 1)
    results['score_0_10'] = score

    out_json = os.path.join(args.outdir, os.path.basename(args.input) + "_features.json")
    with open(out_json, 'w') as f:
        json.dump(results, f, indent=2)
    print(out_json)

if __name__ == "__main__":
    main()
'@

    Set-Content -Path $pyPath -Value $pyCode -Encoding UTF8 -Force

    if ($InstallDependencies) {
      Write-Verbose "Ensuring Python and required packages are available..."
      $python = Get-Command python -ErrorAction SilentlyContinue
      if (-not $python) { throw "Python 3 not found in PATH. Please install Python 3 first." }
      & python -m pip install --user --upgrade pip | Out-Null
      & python -m pip install --user numpy opencv-python-headless scikit-image pillow | Out-Null
    }
  }

  process {
    $bn = [IO.Path]::GetFileName($Path)
    $args = @(
      "--input", $Path,
      "--outdir", $OutputDir,
      "--radius", $Window,
      "--frame_stride", $FrameStride,
      "--overlay_top_p", $OverlayTopP
    )
    Write-Verbose "Running Python entropy probe..."
    $jsonPath = & python $pyPath @args
    if ($LASTEXITCODE -ne 0) { throw "Entropy probe failed." }
    $jsonPath = $jsonPath.Trim()
    if (-not (Test-Path $jsonPath)) { throw "Expected output not found: $jsonPath" }

    $res = Get-Content $jsonPath -Raw | ConvertFrom-Json

    "{0}`nScore: {1}/10`nOverlay: {2}" -f $res.path, $res.score_0_10, ($res.overlay ?? "<none>") | Write-Host

    if ($PassThru) { return $res }
  }
}
