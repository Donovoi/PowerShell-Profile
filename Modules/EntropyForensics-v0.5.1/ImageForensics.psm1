using namespace System.Management.Automation
Set-StrictMode -Version Latest

# region ======== Classes (OOP) ========

class ImageScanOptions {
  [string] $OutputDir
  [int]    $Window = 7
  [int]    $FrameStride = 12
  [double] $OverlayTopP = 0.02
  [bool]   $FaceROI = $false
  [bool]   $JPEGAnalysis = $false
  [int]    $DownscaleMax = 0
  [string] $CsvPath
  [bool]   $InstallDeps = $false
  [bool]   $Legend = $true
  [bool]   $SaveDebugMaps = $false
  [int]    $TimeoutSeconds = 600
}

class ImageScanResult {
  [string]         $Path
  [string]         $Kind
  [double]         $Score
  [string]         $Overlay
  [string]         $FeatureJsonPath
  [string]         $FaceDetector
  [pscustomobject] $Features

  ImageScanResult(
    [string]$Path,
    [string]$Kind,
    [double]$Score,
    [string]$Overlay,
    [string]$FeatureJsonPath,
    [string]$FaceDetector,
    [pscustomobject]$Features
  ) {
    $this.Path = $Path
    $this.Kind = $Kind
    $this.Score = $Score
    $this.Overlay = $Overlay
    $this.FeatureJsonPath = $FeatureJsonPath
    $this.FaceDetector = $FaceDetector
    $this.Features = $Features
  }
}

class ImageScanner {
  [string] $ToolRoot
  [string] $PyPath
  [string] $PythonExe
  [string] $BootstrapPythonExe
  [object] $BootstrapPythonVersion

  ImageScanner() {
    $this.ToolRoot = [ImageScanner]::GetDefaultToolRoot()
    $this.PyPath = Join-Path -Path $this.ToolRoot -ChildPath 'Image_probe_ext.py'
  }

  static [string] GetDefaultToolRoot() {
    $runningOnWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

    if ($runningOnWindows) {
      $baseLocal = [Environment]::GetFolderPath('LocalApplicationData')
      if ([string]::IsNullOrWhiteSpace($baseLocal)) {
        $baseLocal = [IO.Path]::GetTempPath().TrimEnd('\', '/')
      }

      return (Join-Path -Path $baseLocal -ChildPath 'ImageForensics\tools')
    }

    $homePath = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($homePath)) {
      $homePath = [Environment]::GetEnvironmentVariable('HOME', 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($homePath)) {
      $homePath = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    }

    return (Join-Path -Path $homePath -ChildPath '.cache/ImageForensics/tools')
  }

  static [string] GetManagedPythonVersion() {
    return '3.12'
  }

  static [string] GetFullPath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
      return $Path
    }

    if ([IO.Path]::IsPathRooted($Path)) {
      return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
  }

  static [string] GetPythonHelperContent() {
    return @'
import os, sys, argparse, json, math, mimetypes, hashlib
import numpy as np
from PIL import Image
import cv2
from skimage.filters.rank import entropy as rank_entropy
from skimage.morphology import disk
from skimage.color import rgb2ycbcr

try:
    import mediapipe as mp
    MP_AVAILABLE = True
except Exception:
    MP_AVAILABLE = False
    mp = None

def shannon_from_hist(hist):
    p = hist.astype(np.float64)
    s = p.sum() + 1e-12
    p = p / s
    nz = p[p > 0]
    return float(-(nz * np.log2(nz)).sum())

def js_divergence(p, q):
    p = p.astype(np.float64)
    q = q.astype(np.float64)
    p /= (p.sum() + 1e-12)
    q /= (q.sum() + 1e-12)
    m = 0.5 * (p + q)

    def kl(a, b):
        msk = (a > 0) & (b > 0)
        return float((a[msk] * np.log2(a[msk] / b[msk])).sum())

    return 0.5 * kl(p, m) + 0.5 * kl(q, m)

def local_entropy_u8(u8, r):
    return rank_entropy(u8, disk(r))

def to_gray_u8(bgr):
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

def edge_mask(u8):
    med = np.median(u8)
    low = int(max(0, 0.66 * med))
    high = int(min(255, 1.33 * med))
    return (cv2.Canny(u8, low, high) > 0)

def resize_max_dim(bgr, max_dim):
    if max_dim <= 0:
        return bgr, 1.0
    h, w = bgr.shape[:2]
    m = max(h, w)
    if m <= max_dim:
        return bgr, 1.0
    s = max_dim / float(m)
    return cv2.resize(bgr, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA), s

def benford_chi2(vals):
    vals = np.abs(vals).ravel()
    vals = vals[vals > 1e-6]
    if vals.size == 0:
        return 0.0
    ld = np.floor(vals / (10 ** np.floor(np.log10(vals)))).astype(int)
    ld = ld[(ld >= 1) & (ld <= 9)]
    if ld.size == 0:
        return 0.0
    obs = np.bincount(ld, minlength=10)[1:].astype(np.float64)
    obs /= (obs.sum() + 1e-12)
    ben = np.array([np.log10(1 + 1 / d) for d in range(1, 10)], dtype=np.float64)
    return float(((obs - ben) ** 2 / (ben + 1e-12)).sum())

def dct_block_features(gray_u8):
    H, W = gray_u8.shape
    H8, W8 = H // 8 * 8, W // 8 * 8
    if H8 == 0 or W8 == 0:
        return {'dct_band_entropy': [0.0] * 8, 'benford_chi2': 0.0}

    img = gray_u8[:H8, :W8].astype(np.float32) - 128.0
    blocks = []
    for y in range(0, H8, 8):
        for x in range(0, W8, 8):
            blocks.append(cv2.dct(img[y:y+8, x:x+8]))

    if not blocks:
        return {'dct_band_entropy': [0.0] * 8, 'benford_chi2': 0.0}

    D = np.stack(blocks)
    idx = np.arange(64).reshape(8, 8)
    bands = [
        [(0,1),(1,0),(1,1)],
        [(0,2),(2,0),(1,2),(2,1)],
        [(0,3),(3,0),(2,2),(1,3),(3,1)],
        [(0,4),(4,0),(1,4),(4,1),(2,3),(3,2)],
        [(2,4),(4,2),(3,3)],
        [(0,5),(5,0),(1,5),(5,1),(2,5),(5,2),(3,4),(4,3)],
        [(0,6),(6,0),(1,6),(6,1),(2,6),(6,2),(3,5),(5,3),(4,4)],
        [(0,7),(7,0),(1,7),(7,1),(2,7),(7,2),(3,6),(6,3),(4,5),(5,4)]
    ]
    band_feats = []
    Df = D.reshape(-1, 64)

    for b in bands:
        ids = [idx[i, j] for (i, j) in b if not (i == 0 and j == 0)]
        vals = np.abs(Df[:, ids]).ravel()
        hist, _ = np.histogram(vals, bins=64, range=(0, 255))
        band_feats.append(shannon_from_hist(hist))

    ben = benford_chi2(np.abs(D[:, 1:, 1:]))
    return {'dct_band_entropy': band_feats, 'benford_chi2': ben}

def jpeg_qtables(path):
    try:
        with Image.open(path) as im:
            if im.format != 'JPEG':
                return {'is_jpeg': False}
            qt = getattr(im, 'quantization', None)
            if not qt:
                return {'is_jpeg': True, 'qtables': None}
            tables = []
            for k in sorted(qt.keys()):
                tables.append(list(qt[k]))
            flat = np.array([x for t in tables for x in t], dtype=np.int32)
            h = hashlib.sha1(flat.tobytes()).hexdigest()
            return {
                'is_jpeg': True,
                'qtables': tables,
                'qt_hash': h,
                'qt_mean': float(np.mean(flat)),
                'qt_std': float(np.std(flat))
            }
    except Exception:
        return {'is_jpeg': False}

_mp_fd = None

def get_face_detector():
    global _mp_fd
    if MP_AVAILABLE:
        if _mp_fd is None:
            _mp_fd = mp.solutions.face_detection.FaceDetection(
                model_selection=1,
                min_detection_confidence=0.5
            )
        return _mp_fd, 'mediapipe'
    return None, 'haar'

def find_faces(bgr):
    fd, tag = get_face_detector()
    if tag == 'mediapipe':
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        res = fd.process(rgb)
        boxes = []
        if res.detections:
            for d in res.detections:
                bb = d.location_data.relative_bounding_box
                x = max(0, int(bb.xmin * w))
                y = max(0, int(bb.ymin * h))
                ww = int(bb.width * w)
                hh = int(bb.height * h)
                if ww > 0 and hh > 0:
                    boxes.append((x, y, ww, hh))
        return boxes, tag

    cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    faces = cascade.detectMultiScale(gray, 1.1, 5, flags=cv2.CASCADE_SCALE_IMAGE, minSize=(48,48))
    boxes = [] if faces is None else [(int(x), int(y), int(w), int(h)) for (x, y, w, h) in faces]
    return boxes, tag

def boundary_gradient_delta(Ey, face_xywh):
    if face_xywh is None:
        return 0.0
    x, y, w, h = face_xywh
    gy, gx = np.gradient(Ey.astype(np.float32))
    G = np.hypot(gx, gy)
    ring_out = np.zeros_like(G, dtype=bool)
    ring_in = np.zeros_like(G, dtype=bool)
    pad = 6

    y0 = max(0, y - pad)
    y1 = min(G.shape[0], y + h + pad)
    x0 = max(0, x - pad)
    x1 = min(G.shape[1], x + w + pad)

    ring_out[y0:y1, x0:x1] = True
    ring_out[y:y+h, x:x+w] = False
    ring_in[y+2:y+h-2, x+2:x+w-2] = True

    if ring_in.sum() == 0 or ring_out.sum() == 0:
        return 0.0

    return float(G[ring_in].mean() - G[ring_out].mean())

def specular_glint_consistency(bgr, face_xywh):
    if face_xywh is None:
        return {'glint_asym': 0.0, 'glint_irreg': 0.0}

    x, y, w, h = face_xywh
    crop = bgr[y:y+h, x:x+w]
    if crop.size == 0:
        return {'glint_asym': 0.0, 'glint_irreg': 0.0}

    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    V = hsv[..., 2]
    thr = max(200, int(V.mean() + 1.2 * V.std()))
    _, binv = cv2.threshold(V, thr, 255, cv2.THRESH_BINARY)
    cnts, _ = cv2.findContours(binv, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    feats = []
    for c in cnts:
        a = cv2.contourArea(c)
        if a < 4 or a > 150:
            continue
        per = cv2.arcLength(c, True) + 1e-6
        circ = 4 * math.pi * a / (per * per)
        M = cv2.moments(c)
        if M['m00'] > 0:
            cx = int(M['m10'] / M['m00'])
            feats.append((cx, circ))

    if len(feats) < 1:
        return {'glint_asym': 0.0, 'glint_irreg': 0.0}

    xs = [f[0] for f in feats]
    left = sum(1 for v in xs if v < w // 2)
    right = len(xs) - left
    asym = abs(left - right) / max(1.0, len(xs))
    irreg = float(np.mean([abs(1.0 - f[1]) for f in feats]))
    return {'glint_asym': float(asym), 'glint_irreg': float(irreg)}

def frame_entropy_features(frame_bgr, radius, face_roi=False, min_ring_px=10):
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    ycbcr = rgb2ycbcr(rgb).astype(np.uint8)
    Y, Cb, Cr = [ycbcr[..., i] for i in range(3)]

    feats = {}
    chE = {}
    for name, ch in [('Y', Y), ('Cb', Cb), ('Cr', Cr)]:
        E = local_entropy_u8(ch, radius)
        chE[name] = E
        feats[f'{name}_E_mean'] = float(E.mean())
        feats[f'{name}_E_std'] = float(E.std())
        hist, _ = np.histogram(E, bins=32, range=(0, 8))
        feats[f'{name}_E_hist'] = hist.tolist()

    feats['JS_Y_Cb'] = js_divergence(np.array(feats['Y_E_hist']), np.array(feats['Cb_E_hist']))
    feats['JS_Y_Cr'] = js_divergence(np.array(feats['Y_E_hist']), np.array(feats['Cr_E_hist']))

    u8 = to_gray_u8(frame_bgr)
    em = edge_mask(u8)
    fm = ~em
    Ey = chE['Y']

    if em.any() and fm.any():
        feats['E_edge_mean'] = float(Ey[em].mean())
        feats['E_flat_mean'] = float(Ey[fm].mean())
        feats['E_edge_flat_ratio'] = float((Ey[em].mean() + 1e-6) / (Ey[fm].mean() + 1e-6))
    else:
        feats['E_edge_mean'] = 1.0
        feats['E_flat_mean'] = 1.0
        feats['E_edge_flat_ratio'] = 1.0

    mu, sd = Ey.mean(), Ey.std() + 1e-9
    Z = (Ey - mu) / sd
    feats['hotspot_frac'] = float((Z > 2.5).mean())

    faces = []
    det_tag = None
    roi = {}

    if face_roi:
        faces, det_tag = find_faces(frame_bgr)
        if len(faces) > 0:
            x, y, w, h = sorted(faces, key=lambda r: r[2] * r[3], reverse=True)[0]
            roi['face'] = [int(x), int(y), int(w), int(h)]

            faceE = Ey[y:y+h, x:x+w]
            faceZ = (faceE - faceE.mean()) / (faceE.std() + 1e-9)
            roi['face_hotspot_cov'] = float((faceZ > 2.0).mean())
            roi['face_hotspot_int'] = float(np.clip(faceZ[faceZ > 2.0], 0, None).mean() if (faceZ > 2.0).any() else 0.0)
            roi['boundary_grad_delta'] = boundary_gradient_delta(Ey, (x, y, w, h))
            roi.update(specular_glint_consistency(frame_bgr, (x, y, w, h)))

            exp = 0.3
            rx0 = max(0, int(x - exp * w))
            ry0 = max(0, int(y - exp * h))
            rx1 = min(Ey.shape[1], int(x + w * (1 + exp)))
            ry1 = min(Ey.shape[0], int(y + h * (1 + exp)))
            rx0 = max(0, min(rx0, x - min_ring_px))
            ry0 = max(0, min(ry0, y - min_ring_px))
            rx1 = min(Ey.shape[1], max(rx1, x + w + min_ring_px))
            ry1 = min(Ey.shape[0], max(ry1, y + h + min_ring_px))

            ring = np.zeros_like(Ey, dtype=bool)
            ring[ry0:ry1, rx0:rx1] = True
            ring[y:y+h, x:x+w] = False

            bkgE = Ey[ring]
            if faceE.size > 0 and bkgE.size > 0:
                roi['face_E_mean'] = float(faceE.mean())
                roi['bkg_E_mean'] = float(bkgE.mean())
                roi['face_bkg_E_delta'] = float(roi['face_E_mean'] - roi['bkg_E_mean'])

            feats['roi'] = roi

    return feats, chE, faces, det_tag, Z

def temporal_flicker(frames_gray):
    if len(frames_gray) < 3:
        return {'flicker_frac': 0.0, 'std_p95': 0.0}
    F = np.stack(frames_gray, axis=0).astype(np.float32)
    std = F.std(axis=0)
    return {
        'flicker_frac': float((std > 12.0).mean()),
        'std_p95': float(np.percentile(std, 95))
    }

def draw_overlay_native(orig_bgr, Z_work, faces_work, scale_to_orig, out_path, top_p=0.02, legend=True, glints=None):
    H0, W0 = orig_bgr.shape[:2]
    Z = cv2.resize(Z_work, (W0, H0), interpolation=cv2.INTER_CUBIC)
    flat = Z.ravel()
    k = max(1, int(len(flat) * max(0.001, min(0.2, top_p))))
    t = np.partition(flat, -k)[-k]
    mask = (Z >= t).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3,3), np.uint8))
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    Zn = (np.clip(Z, 0, 5) / 5.0 * 255).astype(np.uint8)
    heat = cv2.applyColorMap(Zn, cv2.COLORMAP_JET)
    overlay = cv2.addWeighted(orig_bgr, 0.65, heat, 0.35, 0)

    for (x, y, w, h) in (faces_work or []):
        xs = int(x / scale_to_orig)
        ys = int(y / scale_to_orig)
        ws = int(w / scale_to_orig)
        hs = int(h / scale_to_orig)
        cv2.rectangle(overlay, (xs, ys), (xs + ws, ys + hs), (0, 255, 0), 2)

    cv2.drawContours(overlay, cnts, -1, (0, 0, 255), 2)

    if glints:
        for (gx, gy) in glints:
            cv2.circle(overlay, (gx, gy), 3, (255, 255, 255), -1)

    if legend:
        pad = 8
        box_w, box_h = 380, 110
        x0, y0 = pad, H0 - box_h - pad
        cv2.rectangle(overlay, (x0, y0), (x0 + box_w, y0 + box_h), (0, 0, 0), -1)
        cv2.rectangle(overlay, (x0, y0), (x0 + box_w, y0 + box_h), (200, 200, 200), 1)
        cv2.putText(overlay, 'Legend', (x0 + 10, y0 + 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (220, 220, 220), 1, cv2.LINE_AA)
        cv2.rectangle(overlay, (x0 + 10, y0 + 34), (x0 + 130, y0 + 54), (255, 0, 0), -1)
        cv2.rectangle(overlay, (x0 + 130, y0 + 34), (x0 + 250, y0 + 54), (0, 0, 255), -1)
        cv2.putText(overlay, 'Heatmap: blue->red = rising anomaly', (x0 + 10, y0 + 75), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (220, 220, 220), 1, cv2.LINE_AA)
        cv2.putText(overlay, 'Red contour = top anomalies', (x0 + 10, y0 + 93), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (220, 220, 220), 1, cv2.LINE_AA)
        cv2.putText(overlay, 'Green box = detected face', (x0 + 10, y0 + 109), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (220, 220, 220), 1, cv2.LINE_AA)

    if not cv2.imwrite(out_path, overlay):
        raise SystemExit(f'Failed to write overlay: {out_path}')

    coverage = float(mask.mean())
    return len(cnts), coverage

def byte_entropy_features(path, w=2048, s=1024):
    try:
        data = np.fromfile(path, dtype=np.uint8)
    except Exception:
        data = np.array([], dtype=np.uint8)

    if data.size == 0:
        return {'byte_meanH': 0.0, 'byte_stdH': 0.0, 'byte_p95H': 0.0, 'byte_high_frac': 0.0, 'window': w, 'stride': s}

    Hs = []
    for i in range(0, len(data) - w + 1, s):
        hist, _ = np.histogram(data[i:i+w], bins=256, range=(0, 256))
        Hs.append(shannon_from_hist(hist))

    Hs = np.array(Hs) if Hs else np.array([0.0])
    return {
        'byte_meanH': float(Hs.mean()),
        'byte_stdH': float(Hs.std()),
        'byte_p95H': float(np.percentile(Hs, 95)),
        'byte_high_frac': float((Hs > 7.5).mean()),
        'window': w,
        'stride': s
    }

def is_video(path):
    mt, _ = mimetypes.guess_type(path)
    return (mt or '').startswith('video')

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--outdir', required=True)
    ap.add_argument('--radius', type=int, default=7)
    ap.add_argument('--frame_stride', type=int, default=12)
    ap.add_argument('--overlay_top_p', type=float, default=0.02)
    ap.add_argument('--face_roi', action='store_true')
    ap.add_argument('--jpeg_analysis', action='store_true')
    ap.add_argument('--downscale_max', type=int, default=0)
    ap.add_argument('--legend', action='store_true')
    ap.add_argument('--save_debug', action='store_true')
    args = ap.parse_args()

    args.input = os.path.abspath(args.input)
    args.outdir = os.path.abspath(args.outdir)
    os.makedirs(args.outdir, exist_ok=True)

    res = {
        'path': args.input,
        'params': {
            'radius': args.radius,
            'frame_stride': args.frame_stride,
            'overlay_top_p': args.overlay_top_p,
            'downscale_max': args.downscale_max,
            'face_roi': bool(args.face_roi),
            'jpeg_analysis': bool(args.jpeg_analysis),
            'legend': bool(args.legend),
            'save_debug': bool(args.save_debug)
        },
        'byte': byte_entropy_features(args.input)
    }

    kind = 'video' if is_video(args.input) else 'image'
    res['kind'] = kind
    detector_tag = None

    def score_from_components(res):
        sp = res.get('spatial', {})
        bt = res.get('byte', {})
        tp = res.get('temporal', {'flicker_frac': 0.0, 'std_p95': 0.0})

        hotspot = min(1.0, sp.get('hotspot_frac', 0.0) / 0.06)
        js = max(sp.get('JS_Y_Cb', 0.0), sp.get('JS_Y_Cr', 0.0))
        jsn = min(1.0, js / 0.12)
        ratio = sp.get('E_edge_flat_ratio', 1.0)
        r_anom = float(max(0.0, min(1.0, (ratio - 1.1) / 0.5)))
        flicker = min(1.0, (0.6 * tp.get('flicker_frac', 0.0) + 0.4 * max(0.0, (tp.get('std_p95', 0.0) - 8) / 10)))
        bhigh = min(1.0, bt.get('byte_high_frac', 0.0) / 0.4)

        dct_s = ben_s = qt_s = 0.0
        if 'jpeg_dct' in res:
            bands = res['jpeg_dct'].get('dct_band_entropy', [])
            if len(bands) > 0:
                low = float(np.mean(bands[0:2]))
                high = float(np.mean(bands[-3:]))
                dct_s = float(np.clip((high - low) / 2.0, 0.0, 1.0))
            ben = res['jpeg_dct'].get('benford_chi2', 0.0)
            ben_s = float(np.clip((ben - 2.0) / 6.0, 0.0, 1.0))

        if 'jpeg_qt' in res and res['jpeg_qt'].get('is_jpeg', False):
            qtstd = res['jpeg_qt'].get('qt_std', 0.0)
            qt_s = float(np.clip(abs(qtstd - 20.0) / 25.0, 0.0, 1.0))

        face_cov = sp.get('roi_mean_face_hotspot_frac', sp.get('roi', {}).get('face_hotspot_cov', 0.0))
        face_int = sp.get('roi_mean_face_hotspot_int', sp.get('roi', {}).get('face_hotspot_int', 0.0))
        bgrad = sp.get('roi_mean_boundary_grad_delta', sp.get('roi', {}).get('boundary_grad_delta', 0.0))
        gl_asym = sp.get('roi_mean_glint_asym', sp.get('roi', {}).get('glint_asym', 0.0))
        gl_irreg = sp.get('roi_mean_glint_irreg', sp.get('roi', {}).get('glint_irreg', 0.0))

        face_cov_n = min(1.0, face_cov / 0.15)
        face_int_n = min(1.0, face_int / 1.5)
        bgrad_n = float(np.clip((bgrad - 0.05) / 0.25, 0.0, 1.0))
        glint_n = float(np.clip(0.5 * gl_asym + 0.5 * min(1.0, gl_irreg / 0.6), 0.0, 1.0))

        weights = {
            'face_cov': 0.18, 'face_int': 0.12, 'bgrad': 0.08, 'glint': 0.05,
            'hotspot': 0.12, 'js': 0.07, 'edge': 0.06,
            'temporal': 0.12, 'byte': 0.05, 'dct': 0.08, 'benford': 0.05, 'qt': 0.02
        }

        comps = {
            'face_cov': face_cov_n, 'face_int': face_int_n, 'bgrad': bgrad_n, 'glint': glint_n,
            'hotspot': hotspot, 'js': jsn, 'edge': r_anom,
            'temporal': flicker, 'byte': bhigh, 'dct': dct_s, 'benford': ben_s, 'qt': qt_s
        }

        score01 = sum(weights[k] * comps[k] for k in weights)
        score01 = float(min(1.0, score01 + 0.15 * min(1.0, res.get('overlay_coverage', 0.0) / 0.1)))
        return round(10.0 * max(0.0, min(1.0, score01)), 1), {'weights': weights, 'components': comps}

    if kind == 'image':
        orig = cv2.imread(args.input, cv2.IMREAD_COLOR)
        if orig is None:
            raise SystemExit('Failed to read image.')

        work, scale = resize_max_dim(orig, args.downscale_max)
        feats, chE, faces, detector_tag, Z = frame_entropy_features(work, args.radius, args.face_roi)
        res['spatial'] = feats
        res['face_detector'] = detector_tag

        if args.jpeg_analysis:
            gray = to_gray_u8(work)
            res['jpeg_dct'] = dct_block_features(gray)
            res['jpeg_qt'] = jpeg_qtables(args.input)

        ov = os.path.abspath(os.path.join(args.outdir, os.path.basename(args.input) + '_overlay.png'))
        gl_vis = []
        scale_to_orig = scale if scale > 0 else 1.0

        if 'roi' in feats and 'face' in feats['roi']:
            x, y, w, h = feats['roi']['face']
            xs = max(0, int(round(x / scale_to_orig)))
            ys = max(0, int(round(y / scale_to_orig)))
            ws = max(1, int(round(w / scale_to_orig)))
            hs = max(1, int(round(h / scale_to_orig)))

            xe = min(orig.shape[1], xs + ws)
            ye = min(orig.shape[0], ys + hs)
            crop = orig[ys:ye, xs:xe]

            if crop.size > 0:
                hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
                V = hsv[..., 2]
                thr = max(200, int(V.mean() + 1.2 * V.std()))
                _, binv = cv2.threshold(V, thr, 255, cv2.THRESH_BINARY)
                cnts, _ = cv2.findContours(binv, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

                for c in cnts:
                    a = cv2.contourArea(c)
                    if a < 4 or a > 150:
                        continue
                    M = cv2.moments(c)
                    if M['m00'] > 0:
                        cx = int(M['m10'] / M['m00']) + xs
                        cy = int(M['m01'] / M['m00']) + ys
                        gl_vis.append((cx, cy))

        _, overlay_coverage = draw_overlay_native(orig, Z, faces, scale_to_orig, ov, args.overlay_top_p, legend=args.legend, glints=gl_vis)
        res['overlay'] = ov
        res['overlay_coverage'] = overlay_coverage
        res['temporal'] = {'flicker_frac': 0.0, 'std_p95': 0.0}

        score, scdetail = score_from_components(res)
        res['score_0_10'] = score
        res['score_components'] = scdetail

        if args.save_debug:
            z_path = os.path.abspath(os.path.join(args.outdir, os.path.basename(args.input) + '_Z.png'))
            if not cv2.imwrite(z_path, (np.clip(Z, 0, 5) / 5.0 * 255).astype(np.uint8)):
                raise SystemExit(f'Failed to write debug map: {z_path}')

    else:
        cap = cv2.VideoCapture(args.input)
        if not cap.isOpened():
            raise SystemExit('Failed to open video.')

        frames_gray = []
        spatial = []
        rep = None
        f = 0

        while True:
            ret = cap.grab()
            if not ret:
                break

            if (f % args.frame_stride) == 0:
                ret, frm = cap.retrieve()
                if not ret:
                    break

                work, scale = resize_max_dim(frm, args.downscale_max)
                feats, chE, faces, detector_tag_frame, Z = frame_entropy_features(work, args.radius, args.face_roi)

                if detector_tag is None and detector_tag_frame:
                    detector_tag = detector_tag_frame

                spatial.append(feats)
                frames_gray.append(to_gray_u8(work))
                rep = (frm, Z, faces, (scale if scale > 0 else 1.0))

            f += 1

        cap.release()

        if not spatial:
            raise SystemExit('No frames sampled. Try smaller --frame_stride.')

        agg = {}
        first = spatial[0]

        for k in first.keys():
            if k.endswith('_hist') or k == 'roi':
                continue
            agg[k] = float(np.mean([s[k] for s in spatial]))

        for c in ['Y', 'Cb', 'Cr']:
            hsum = np.sum([s[f'{c}_E_hist'] for s in spatial], axis=0)
            agg[f'{c}_E_hist'] = hsum.tolist()

        if any('roi' in s for s in spatial):
            fbd = [s['roi'].get('face_bkg_E_delta', 0.0) for s in spatial if 'roi' in s]
            fhf = [s['roi'].get('face_hotspot_cov', 0.0) for s in spatial if 'roi' in s]
            fint = [s['roi'].get('face_hotspot_int', 0.0) for s in spatial if 'roi' in s]
            bgrd = [s['roi'].get('boundary_grad_delta', 0.0) for s in spatial if 'roi' in s]
            gasy = [s['roi'].get('glint_asym', 0.0) for s in spatial if 'roi' in s]
            girr = [s['roi'].get('glint_irreg', 0.0) for s in spatial if 'roi' in s]

            agg['roi_mean_face_bkg_E_delta'] = float(np.mean(fbd)) if fbd else 0.0
            agg['roi_mean_face_hotspot_frac'] = float(np.mean(fhf)) if fhf else 0.0
            agg['roi_mean_face_hotspot_int'] = float(np.mean(fint)) if fint else 0.0
            agg['roi_mean_boundary_grad_delta'] = float(np.mean(bgrd)) if bgrd else 0.0
            agg['roi_mean_glint_asym'] = float(np.mean(gasy)) if gasy else 0.0
            agg['roi_mean_glint_irreg'] = float(np.mean(girr)) if girr else 0.0

        res['spatial'] = agg
        res['temporal'] = temporal_flicker(frames_gray)
        res['face_detector'] = detector_tag

        if rep:
            frm, Z_work, faces_work, s = rep
            ov = os.path.abspath(os.path.join(args.outdir, os.path.basename(args.input) + '_overlay.png'))
            _, overlay_coverage = draw_overlay_native(frm, Z_work, faces_work, s, ov, args.overlay_top_p, legend=args.legend)
            res['overlay'] = ov
            res['overlay_coverage'] = overlay_coverage

        score, scdetail = score_from_components(res)
        res['score_0_10'] = score
        res['score_components'] = scdetail

    out_json = os.path.abspath(os.path.join(args.outdir, os.path.basename(args.input) + '_features.json'))
    with open(out_json, 'w', encoding='utf-8') as f:
        json.dump(res, f, indent=2)

    print(out_json)

if __name__ == '__main__':
    main()
'@
  }

  hidden [void] EnsureToolRoot() {
    if (-not (Test-Path -LiteralPath $this.ToolRoot -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $this.ToolRoot | Out-Null
    }
  }

  hidden [void] EnsurePythonHelper() {
    $this.EnsureToolRoot()
    $desired = [ImageScanner]::GetPythonHelperContent()
    $current = $null

    if (Test-Path -LiteralPath $this.PyPath -PathType Leaf) {
      $current = Get-Content -LiteralPath $this.PyPath -Raw -ErrorAction SilentlyContinue
    }

    if ($current -ne $desired) {
      Set-Content -LiteralPath $this.PyPath -Value $desired -Encoding UTF8 -Force
    }
  }

  hidden [string] GetManagedVenvPath() {
    return (Join-Path -Path (Split-Path -Path $this.ToolRoot -Parent) -ChildPath '.venv')
  }

  hidden [string] GetManagedPythonPath() {
    $venvPath = $this.GetManagedVenvPath()
    $runningOnWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

    if ($runningOnWindows) {
      return (Join-Path -Path $venvPath -ChildPath 'Scripts\python.exe')
    }

    return (Join-Path -Path $venvPath -ChildPath 'bin/python')
  }

  hidden [string] GetLastOutputLine([string[]] $Lines) {
    $nonEmpty = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -eq 0) {
      return $null
    }

    return [string]$nonEmpty[-1]
  }

  hidden [pscustomobject] InvokeExternal([string] $Executable, [string[]] $Arguments, [int] $TimeoutSeconds) {
    $result = $null
    $job = Start-Job -ScriptBlock {
      param(
        [string] $Exe,
        [string[]] $ExeArgs
      )

      $ErrorActionPreference = 'Stop'
      try {
        $output = & $Exe @ExeArgs 2>&1 | ForEach-Object { $_.ToString() }
        [pscustomobject]@{
          ExitCode = if ($null -ne $LASTEXITCODE) {
            [int]$LASTEXITCODE 
          }
          else {
            0 
          }
          Output   = @($output)
        }
      }
      catch {
        [pscustomobject]@{
          ExitCode = -1
          Output   = @($_.Exception.Message)
        }
      }
    } -ArgumentList $Executable, $Arguments

    try {
      if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        Stop-Job -Job $job -Force | Out-Null
        throw "The process '$Executable' did not finish within $TimeoutSeconds second(s)."
      }

      $result = Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($result -is [array]) {
      $result = $result[-1]
    }

    $lines = @()
    if ($null -ne $result.Output) {
      $lines = @($result.Output | ForEach-Object { $_.ToString() })
    }

    return [pscustomobject]@{
      ExitCode = [int]$result.ExitCode
      Output   = $lines
      Text     = ($lines -join [Environment]::NewLine)
    }
  }

  hidden [void] WritePythonVersionWarnings([object] $Version) {
    if ([int]$Version.major -ne 3) {
      return
    }

    if ([int]$Version.minor -lt 10) {
      Write-Warning ('Python {0}.{1} is older than the recommended 3.10+ baseline. Some wheels may be unavailable.' -f $Version.major, $Version.minor)
    }

    if ([int]$Version.minor -ge 13) {
      Write-Warning ('Python {0}.{1} detected. MediaPipe wheels may be unavailable; face ROI may fall back to Haar detection.' -f $Version.major, $Version.minor)
    }
  }

  hidden [pscustomobject] GetPythonVersion([string] $PythonExe, [int] $TimeoutSeconds) {
    $script = @'
import json, sys
print(json.dumps({"major": sys.version_info[0], "minor": sys.version_info[1], "micro": sys.version_info[2]}))
'@
    $result = $this.InvokeExternal($PythonExe, @('-c', $script), $TimeoutSeconds)
    if ($result.ExitCode -ne 0) {
      throw "Failed to query Python version using '$PythonExe'. $($result.Text)"
    }

    $jsonLine = $this.GetLastOutputLine($result.Output)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
      throw 'Python version check did not return any output.'
    }

    return ($jsonLine | ConvertFrom-Json -ErrorAction Stop)
  }

  hidden [string] ResolveBootstrapPythonCommand([ImageScanOptions] $Options) {
    if (-not [string]::IsNullOrWhiteSpace($this.BootstrapPythonExe)) {
      return $this.BootstrapPythonExe
    }

    foreach ($candidate in @('python', 'python3')) {
      $cmd = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $cmd) {
        continue
      }

      $exe = if ($cmd.Path) {
        $cmd.Path 
      }
      else {
        $cmd.Source 
      }
      if ([string]::IsNullOrWhiteSpace($exe)) {
        $exe = $cmd.Name
      }

      try {
        $version = $this.GetPythonVersion($exe, $Options.TimeoutSeconds)
      }
      catch {
        Write-Verbose ("Skipping Python candidate '{0}': {1}" -f $candidate, $_.Exception.Message)
        continue
      }

      if ([int]$version.major -ne 3) {
        continue
      }

      Write-Verbose ('Using bootstrap Python executable: {0} ({1}.{2}.{3})' -f $exe, $version.major, $version.minor, $version.micro)
      $this.BootstrapPythonExe = $exe
      $this.BootstrapPythonVersion = $version
      return $this.BootstrapPythonExe
    }

    throw "Python 3 was not found on PATH. Install Python 3 and try again. '-InstallDependencies' can install packages, but it cannot install Python itself."
  }

  hidden [string] ResolvePythonCommand([ImageScanOptions] $Options) {
    if (-not [string]::IsNullOrWhiteSpace($this.PythonExe)) {
      return $this.PythonExe
    }

    $managedPython = $this.GetManagedPythonPath()
    if (Test-Path -LiteralPath $managedPython -PathType Leaf) {
      try {
        $managedVersion = $this.GetPythonVersion($managedPython, $Options.TimeoutSeconds)
        if ([int]$managedVersion.major -eq 3) {
          $this.WritePythonVersionWarnings($managedVersion)
          Write-Verbose ('Using uv-managed Python executable: {0} ({1}.{2}.{3})' -f $managedPython, $managedVersion.major, $managedVersion.minor, $managedVersion.micro)
          $this.PythonExe = $managedPython
          return $this.PythonExe
        }
      }
      catch {
        Write-Verbose ("Skipping uv-managed Python candidate '{0}': {1}" -f $managedPython, $_.Exception.Message)
      }
    }

    $bootstrapPython = $this.ResolveBootstrapPythonCommand($Options)
    $bootstrapVersion = $this.BootstrapPythonVersion
    if ($null -eq $bootstrapVersion) {
      $bootstrapVersion = $this.GetPythonVersion($bootstrapPython, $Options.TimeoutSeconds)
      $this.BootstrapPythonVersion = $bootstrapVersion
    }

    $this.WritePythonVersionWarnings($bootstrapVersion)
    Write-Verbose ('Using system Python executable: {0} ({1}.{2}.{3})' -f $bootstrapPython, $bootstrapVersion.major, $bootstrapVersion.minor, $bootstrapVersion.micro)
    $this.PythonExe = $bootstrapPython
    return $this.PythonExe
  }

  hidden [void] EnsurePipAvailable([string] $PythonExe, [int] $TimeoutSeconds) {
    $pipCheck = $this.InvokeExternal($PythonExe, @('-m', 'pip', '--version'), $TimeoutSeconds)
    if ($pipCheck.ExitCode -eq 0) {
      return
    }

    Write-Verbose ('pip is unavailable for {0}; attempting ensurepip bootstrap.' -f $PythonExe)
    $ensurePip = $this.InvokeExternal($PythonExe, @('-m', 'ensurepip', '--upgrade'), $TimeoutSeconds)
    if ($ensurePip.ExitCode -ne 0) {
      throw ("Failed to bootstrap pip for '{0}'. {1}" -f $PythonExe, $ensurePip.Text)
    }
  }

  hidden [void] EnsureUvAvailable([string] $BootstrapPythonExe, [ImageScanOptions] $Options) {
    $uvCheck = $this.InvokeExternal($BootstrapPythonExe, @('-m', 'uv', '--version'), $Options.TimeoutSeconds)
    if ($uvCheck.ExitCode -eq 0) {
      $uvVersionLine = $this.GetLastOutputLine($uvCheck.Output)
      if ([string]::IsNullOrWhiteSpace($uvVersionLine)) {
        Write-Verbose ("Using uv via '{0} -m uv'." -f $BootstrapPythonExe)
      }
      else {
        Write-Verbose ("Using uv via '{0} -m uv' ({1})." -f $BootstrapPythonExe, $uvVersionLine)
      }
      return
    }

    $this.EnsurePipAvailable($BootstrapPythonExe, $Options.TimeoutSeconds)
    Write-Verbose ('Installing/repairing uv with bootstrap Python {0}.' -f $BootstrapPythonExe)
    $installResult = $this.InvokeExternal($BootstrapPythonExe, @('-m', 'pip', 'install', '--user', '--upgrade', 'uv'), $Options.TimeoutSeconds)
    if ($installResult.ExitCode -ne 0) {
      throw ("Failed to install uv with '{0}'. {1}" -f $BootstrapPythonExe, $installResult.Text)
    }

    $uvCheck = $this.InvokeExternal($BootstrapPythonExe, @('-m', 'uv', '--version'), $Options.TimeoutSeconds)
    if ($uvCheck.ExitCode -ne 0) {
      throw ('uv is still unavailable after installation. {0}' -f $uvCheck.Text)
    }

    $uvVersionLine = $this.GetLastOutputLine($uvCheck.Output)
    if ([string]::IsNullOrWhiteSpace($uvVersionLine)) {
      Write-Verbose ("Installed uv via '{0} -m uv'." -f $BootstrapPythonExe)
    }
    else {
      Write-Verbose ("Installed uv via '{0} -m uv' ({1})." -f $BootstrapPythonExe, $uvVersionLine)
    }
  }

  hidden [string] EnsureManagedPythonEnvironment([string] $BootstrapPythonExe, [ImageScanOptions] $Options) {
    $this.EnsureToolRoot()
    $this.EnsureUvAvailable($BootstrapPythonExe, $Options)

    $venvPath = $this.GetManagedVenvPath()
    $venvResult = $this.InvokeExternal(
      $BootstrapPythonExe,
      @('-m', 'uv', 'venv', '--python', [ImageScanner]::GetManagedPythonVersion(), $venvPath),
      $Options.TimeoutSeconds
    )

    if ($venvResult.ExitCode -ne 0) {
      throw ("Failed to create the uv-managed Python environment at '{0}'. {1}" -f $venvPath, $venvResult.Text)
    }

    $managedPython = $this.GetManagedPythonPath()
    if (-not (Test-Path -LiteralPath $managedPython -PathType Leaf)) {
      throw ("uv created '{0}', but the environment Python '{1}' was not found." -f $venvPath, $managedPython)
    }

    $managedVersion = $this.GetPythonVersion($managedPython, $Options.TimeoutSeconds)
    $this.WritePythonVersionWarnings($managedVersion)
    Write-Verbose ('Using uv-managed Python executable: {0} ({1}.{2}.{3})' -f $managedPython, $managedVersion.major, $managedVersion.minor, $managedVersion.micro)
    $this.PythonExe = $managedPython
    return $managedPython
  }

  hidden [void] InstallPackagesWithUv([string] $BootstrapPythonExe, [string] $TargetPythonExe, [string[]] $Packages, [bool] $Optional, [int] $TimeoutSeconds) {
    $uniquePackages = @(
      $Packages |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Select-Object -Unique
    )

    if ($uniquePackages.Count -eq 0) {
      return
    }

    $packageList = $uniquePackages -join ', '
    $dependencyKind = if ($Optional) {
      'optional' 
    }
    else {
      'required' 
    }
    Write-Verbose ('Installing/repairing {0} Python dependencies with uv: {1}' -f $dependencyKind, $packageList)

    $installArgs = @('-m', 'uv', 'pip', 'install', '--python', $TargetPythonExe, '--upgrade') + $uniquePackages
    $installResult = $this.InvokeExternal($BootstrapPythonExe, $installArgs, $TimeoutSeconds)
    if ($installResult.ExitCode -ne 0) {
      if ($Optional) {
        Write-Warning ('uv could not install optional Python package(s): {0}. {1}' -f $packageList, $installResult.Text)
        return
      }

      throw ('uv failed to install required Python package(s): {0}. {1}' -f $packageList, $installResult.Text)
    }
  }

  hidden [pscustomobject] GetPackageStatus([string] $PythonExe, [int] $TimeoutSeconds) {
    $script = @'
import importlib, json

required = [
    ("numpy", "numpy"),
    ("cv2", "opencv-python-headless"),
    ("skimage", "scikit-image"),
    ("PIL", "pillow"),
]
optional = [
    ("mediapipe", "mediapipe"),
]

status = {"missing_required": [], "missing_optional": []}

for module_name, package_name in required:
    try:
        importlib.import_module(module_name)
    except Exception:
        status["missing_required"].append(package_name)

for module_name, package_name in optional:
    try:
        importlib.import_module(module_name)
    except Exception:
        status["missing_optional"].append(package_name)

print(json.dumps(status))
'@

    $result = $this.InvokeExternal($PythonExe, @('-c', $script), $TimeoutSeconds)
    if ($result.ExitCode -ne 0) {
      throw "Failed to validate Python dependencies. $($result.Text)"
    }

    $jsonLine = $this.GetLastOutputLine($result.Output)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
      throw 'Dependency validation returned no output.'
    }

    return ($jsonLine | ConvertFrom-Json -ErrorAction Stop)
  }

  hidden [string] EnsurePythonDependencies([ImageScanOptions] $Options) {
    $resolvedBootstrapPython = $null
    $resolvedPython = $null

    if ($Options.InstallDeps) {
      $resolvedBootstrapPython = $this.ResolveBootstrapPythonCommand($Options)
      $resolvedPython = $this.EnsureManagedPythonEnvironment($resolvedBootstrapPython, $Options)
    }
    else {
      $resolvedPython = $this.ResolvePythonCommand($Options)
    }

    $status = $this.GetPackageStatus($resolvedPython, $Options.TimeoutSeconds)
    $missingRequired = @($status.missing_required)
    $missingOptional = @($status.missing_optional)

    if ($Options.InstallDeps -and (($missingRequired.Count -gt 0) -or ($missingOptional.Count -gt 0))) {
      if ([string]::IsNullOrWhiteSpace($resolvedBootstrapPython)) {
        $resolvedBootstrapPython = $this.ResolveBootstrapPythonCommand($Options)
      }

      if ($missingRequired.Count -gt 0) {
        $this.InstallPackagesWithUv($resolvedBootstrapPython, $resolvedPython, @($missingRequired), $false, $Options.TimeoutSeconds)
      }

      if ($missingOptional.Count -gt 0) {
        $this.InstallPackagesWithUv($resolvedBootstrapPython, $resolvedPython, @($missingOptional), $true, $Options.TimeoutSeconds)
      }

      $status = $this.GetPackageStatus($resolvedPython, $Options.TimeoutSeconds)
      $missingRequired = @($status.missing_required)
      $missingOptional = @($status.missing_optional)
    }

    if ($missingRequired.Count -gt 0) {
      $packageList = $missingRequired -join ', '
      throw ('Missing required Python packages: {0}. Re-run with -InstallDependencies or install them manually with: uv pip install --python "{1}" --upgrade {2}' -f $packageList, $resolvedPython, $packageList)
    }

    if ($missingOptional.Count -gt 0 -and $Options.FaceROI) {
      Write-Warning ('Optional Python package(s) missing: {0}. Face ROI will use OpenCV Haar fallback when possible.' -f ($missingOptional -join ', '))
    }

    $this.PythonExe = $resolvedPython
    return $resolvedPython
  }

  hidden [void] AppendCsv([string] $CsvPath, [pscustomobject] $Row) {
    $csvFullPath = [ImageScanner]::GetFullPath($CsvPath)
    $csvDirectory = Split-Path -Path $csvFullPath -Parent

    if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -LiteralPath $csvDirectory -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $csvDirectory | Out-Null
    }

    if (Test-Path -LiteralPath $csvFullPath -PathType Leaf) {
      $Row | Export-Csv -Path $csvFullPath -NoTypeInformation -Append
    }
    else {
      $Row | Export-Csv -Path $csvFullPath -NoTypeInformation
    }
  }

  hidden [string] InvokeProbe([string] $PythonExe, [string[]] $Arguments, [int] $TimeoutSeconds) {
    $result = $this.InvokeExternal($PythonExe, $Arguments, $TimeoutSeconds)

    if ($result.ExitCode -ne 0) {
      throw ('Probe failed. {0}' -f $result.Text)
    }

    $jsonPath = $this.GetLastOutputLine($result.Output)
    if ([string]::IsNullOrWhiteSpace($jsonPath)) {
      throw 'Probe finished without reporting a features JSON path.'
    }

    return $jsonPath.Trim()
  }

  [ImageScanResult] InvokeOne([string] $Path, [ImageScanOptions] $Options) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw [IO.FileNotFoundException]::new("File not found: $Path")
    }

    $inputPath = [ImageScanner]::GetFullPath($Path)
    $outputDir = if ([string]::IsNullOrWhiteSpace($Options.OutputDir)) {
      Join-Path -Path (Split-Path -Path $inputPath -Parent) -ChildPath 'Image-output'
    }
    else {
      [ImageScanner]::GetFullPath($Options.OutputDir)
    }

    $resolvedPythonExe = $this.EnsurePythonDependencies($Options)
    $this.EnsurePythonHelper()

    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $pyArgs = @(
      $this.PyPath,
      '--input', $inputPath,
      '--outdir', $outputDir,
      '--radius', $Options.Window.ToString($culture),
      '--frame_stride', $Options.FrameStride.ToString($culture),
      '--overlay_top_p', $Options.OverlayTopP.ToString($culture),
      '--downscale_max', $Options.DownscaleMax.ToString($culture)
    )

    if ($Options.FaceROI) {
      $pyArgs += '--face_roi'
    }
    if ($Options.JPEGAnalysis) {
      $pyArgs += '--jpeg_analysis'
    }
    if ($Options.Legend) {
      $pyArgs += '--legend'
    }
    if ($Options.SaveDebugMaps) {
      $pyArgs += '--save_debug'
    }

    Write-Verbose ("Scanning '{0}'..." -f $inputPath)
    $jsonPath = $this.InvokeProbe($resolvedPythonExe, $pyArgs, $Options.TimeoutSeconds)

    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
      throw "The Python helper reported '$jsonPath', but that file does not exist."
    }

    $jsonRaw = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop
    try {
      $res = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
      throw "Failed to parse JSON output from '$jsonPath'. $($_.Exception.Message)"
    }

    foreach ($requiredProperty in @('path', 'kind', 'score_0_10', 'overlay')) {
      if ($res.PSObject.Properties.Name -notcontains $requiredProperty) {
        throw "The Python helper output is missing required property '$requiredProperty'."
      }
    }

    $faceDetector = $null
    if ($res.PSObject.Properties.Name -contains 'face_detector') {
      $faceDetector = [string]$res.face_detector
    }

    if (-not [string]::IsNullOrWhiteSpace($Options.CsvPath)) {
      $spatial = $res.spatial
      $roi = $null
      if ($spatial -and ($spatial.PSObject.Properties.Name -contains 'roi')) {
        $roi = $spatial.roi
      }

      $hotspotFrac = 0.0
      if ($spatial -and ($spatial.PSObject.Properties.Name -contains 'hotspot_frac') -and $null -ne $spatial.hotspot_frac) {
        $hotspotFrac = [double]$spatial.hotspot_frac
      }

      $faceHotCov = 0.0
      if ($spatial -and ($spatial.PSObject.Properties.Name -contains 'roi_mean_face_hotspot_frac') -and $null -ne $spatial.roi_mean_face_hotspot_frac) {
        $faceHotCov = [double]$spatial.roi_mean_face_hotspot_frac
      }
      elseif ($roi -and ($roi.PSObject.Properties.Name -contains 'face_hotspot_cov') -and $null -ne $roi.face_hotspot_cov) {
        $faceHotCov = [double]$roi.face_hotspot_cov
      }

      $byteHighFrac = 0.0
      if ($res.byte -and ($res.byte.PSObject.Properties.Name -contains 'byte_high_frac') -and $null -ne $res.byte.byte_high_frac) {
        $byteHighFrac = [double]$res.byte.byte_high_frac
      }

      $flickerFrac = 0.0
      if ($res.temporal -and ($res.temporal.PSObject.Properties.Name -contains 'flicker_frac') -and $null -ne $res.temporal.flicker_frac) {
        $flickerFrac = [double]$res.temporal.flicker_frac
      }

      $row = [pscustomobject][ordered]@{
        Path         = [string]$res.path
        Kind         = [string]$res.kind
        Score        = [double]$res.score_0_10
        Overlay      = [string]$res.overlay
        FeatureJson  = [string]$jsonPath
        HotspotFrac  = $hotspotFrac
        FaceHotCov   = $faceHotCov
        ByteHighFrac = $byteHighFrac
        FlickerFrac  = $flickerFrac
        FaceDetector = $faceDetector
      }

      try {
        $this.AppendCsv($Options.CsvPath, $row)
      }
      catch {
        Write-Warning ("Failed to write CSV '{0}': {1}" -f $Options.CsvPath, $_.Exception.Message)
      }
    }

    return [ImageScanResult]::new(
      [string]$res.path,
      [string]$res.kind,
      [double]$res.score_0_10,
      [string]$res.overlay,
      [string]$jsonPath,
      $faceDetector,
      [pscustomobject]$res
    )
  }
}

# endregion ======== Classes ========

function Invoke-DeepfakeScan {
  <#
.SYNOPSIS
Scans image and video files for manipulation indicators and writes overlays plus structured feature output.

.DESCRIPTION
Invoke-DeepfakeScan performs local media triage by combining:
- Spatial entropy analysis on Y/Cb/Cr channels
- Edge-versus-flat entropy comparisons
- Optional JPEG DCT / Benford / quantization-table analysis for still images
- Optional face-focused metrics such as hotspot coverage and glint consistency
- Temporal flicker analysis for video
- Overlay generation and JSON feature output for downstream review

The cmdlet shells out to Python for the heavy image-processing work. It supports
pipeline input, `-WhatIf`, optional dependency installation, CSV summaries, and
friendly preflight checks for missing Python packages.

.PARAMETER Path
One or more image or video files to scan. Accepts pipeline input and `FullName`
property binding.

.PARAMETER OutputDir
Directory used for overlay images and JSON feature files. When omitted, output is
written to a sibling `Image-output` folder next to the input file.

.PARAMETER Window
Local entropy radius. Must be an odd number between 3 and 31. The default is 7.

.PARAMETER FrameStride
For videos, sample every Nth frame. The default is 12.

.PARAMETER OverlayTopP
Top fraction of anomaly z-scores used for contour overlays. The default is 0.02.

.PARAMETER FaceROI
Enables face-focused analysis and face box overlays.

.PARAMETER JPEGAnalysis
Enables JPEG-specific still-image analysis.

.PARAMETER DownscaleMax
Maximum dimension used during processing. Use 0 to disable downscaling.

.PARAMETER CsvPath
Optional CSV path used to append a stable summary row per scanned file.

.PARAMETER InstallDependencies
When specified, the cmdlet bootstraps `uv` if needed, creates or refreshes a
managed Python 3.12 environment for ImageForensics, and installs or repairs
missing Python packages before scanning.

.PARAMETER Legend
Controls whether the overlay legend is drawn. Defaults to `$true`.

.PARAMETER SaveDebugMaps
Saves the intermediate anomaly map (`_Z.png`) next to the normal output.

.PARAMETER TimeoutSeconds
Maximum time to allow each Python subprocess to run before the scan is aborted.
The default is 600 seconds.

.EXAMPLE
Invoke-DeepfakeScan -Path .\sample.jpg -JPEGAnalysis -FaceROI -Verbose

Scans a still image, enables JPEG and face-focused analysis, and emits verbose
progress information.

.EXAMPLE
Get-ChildItem .\evidence\*.mp4 | Invoke-DeepfakeScan -FrameStride 6 -OutputDir .\triage

Scans multiple video files from the pipeline and writes overlays/JSON results to
a shared output folder.

.EXAMPLE
Invoke-DeepfakeScan -Path .\sample.jpg -InstallDependencies -CsvPath .\results\triage.csv

Validates Python dependencies, installs missing packages when needed, runs the
scan, and appends a summary row to a CSV file.

.INPUTS
System.String

.OUTPUTS
ImageScanResult

.NOTES
- Python 3 must be installed and available on PATH as `python` or `python3`.
- `-InstallDependencies` bootstraps `uv` if needed and manages packages inside a dedicated ImageForensics virtual environment.
- `-WhatIf` prevents helper creation, output directory creation, Python execution, and CSV writes.
#>
  [OutputType([ImageScanResult])]
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = 'Path to an image or video file to scan.')]
    [Alias('FullName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [Parameter(HelpMessage = 'Output directory for overlays and JSON feature files. Defaults to a sibling Image-output folder.')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDir,

    [Parameter(HelpMessage = 'Local entropy radius. Must be an odd value between 3 and 31.')]
    [ValidateRange(3, 31)]
    [ValidateScript({ ($_ % 2) -eq 1 })]
    [int]$Window = 7,

    [Parameter(HelpMessage = 'Sample every Nth frame when scanning videos.')]
    [ValidateRange(1, 300)]
    [int]$FrameStride = 12,

    [Parameter(HelpMessage = 'Top fraction of anomaly z-scores to contour in the overlay.')]
    [ValidateRange(0.001, 0.2)]
    [double]$OverlayTopP = 0.02,

    [Parameter(HelpMessage = 'Enable face-focused analysis and face box overlays.')]
    [switch]$FaceROI,

    [Parameter(HelpMessage = 'Enable JPEG-specific analysis on still images.')]
    [switch]$JPEGAnalysis,

    [Parameter(HelpMessage = 'Maximum processing dimension. Use 0 to disable downscaling.')]
    [ValidateRange(0, 32768)]
    [int]$DownscaleMax = 0,

    [Parameter(HelpMessage = 'Optional CSV path used to append one summary row per scanned file.')]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(HelpMessage = 'Bootstrap uv, create or refresh the managed Python environment, and install or repair missing Python packages before scanning.')]
    [switch]$InstallDependencies,

    [Parameter(HelpMessage = 'Draw the overlay legend. Defaults to $true.')]
    [bool]$Legend = $true,

    [Parameter(HelpMessage = 'Write an intermediate anomaly map (_Z.png) to disk.')]
    [switch]$SaveDebugMaps,

    [Parameter(HelpMessage = 'Maximum time to wait for each Python subprocess.')]
    [ValidateRange(30, 7200)]
    [int]$TimeoutSeconds = 600
  )

  begin {
    $scanner = $null

    $options = [ImageScanOptions]::new()
    $options.OutputDir = $OutputDir
    $options.Window = $Window
    $options.FrameStride = $FrameStride
    $options.OverlayTopP = $OverlayTopP
    $options.FaceROI = [bool]$FaceROI
    $options.JPEGAnalysis = [bool]$JPEGAnalysis
    $options.DownscaleMax = $DownscaleMax
    $options.CsvPath = $CsvPath
    $options.InstallDeps = [bool]$InstallDependencies
    $options.Legend = $Legend
    $options.SaveDebugMaps = [bool]$SaveDebugMaps
    $options.TimeoutSeconds = $TimeoutSeconds
  }

  process {
    foreach ($item in $Path) {
      if (-not $PSCmdlet.ShouldProcess($item, 'Scan media and write overlay/feature artifacts')) {
        continue
      }

      if (-not $scanner) {
        $scanner = [ImageScanner]::new()
      }

      try {
        $result = $scanner.InvokeOne($item, $options)
        Write-Verbose ("Completed scan for '{0}' (score: {1}/10)" -f $result.Path, $result.Score)
        $result
      }
      catch {
        $PSCmdlet.WriteError($_)
      }
    }
  }
}

Export-ModuleMember -Function Invoke-DeepfakeScan
