
using namespace System.Collections.Generic

# region ======== Classes (OOP) ========

class EntropyScanOptions {
  [string]   $OutputDir
  [int]      $Window        = 7
  [int]      $FrameStride   = 12
  [double]   $OverlayTopP   = 0.02
  [bool]     $FaceROI       = $true
  [bool]     $JPEGAnalysis  = $true
  [int]      $DownscaleMax  = 0       # 0 = no downscale; else max(H,W)
  [string]   $CsvPath
  [bool]     $InstallDeps   = $false
}

class EntropyScanResult {
  [string]         $Path
  [string]         $Kind
  [double]         $Score
  [string]         $Overlay
  [string]         $FeatureJsonPath
  [pscustomobject] $Features
  EntropyScanResult([string]$p,[string]$k,[double]$s,[string]$ov,[string]$fj,[pscustomobject]$feat){
    $this.Path=$p; $this.Kind=$k; $this.Score=$s; $this.Overlay=$ov; $this.FeatureJsonPath=$fj; $this.Features=$feat
  }
}

class EntropyScanner {
  [string] $ToolRoot
  [string] $PyPath
  EntropyScanner() {
    # Write helper to user-writable cache
    if ($IsWindows) {
      $baseLocal = [Environment]::GetFolderPath('LocalApplicationData')
      if (-not $baseLocal) { $baseLocal = Join-Path $env:USERPROFILE 'AppData\Local' }
      $this.ToolRoot = Join-Path $baseLocal 'EntropyForensics\tools'
    } else {
      $homePath = $HOME   # do not reassign automatic variable
      $this.ToolRoot = Join-Path $homePath '.cache/EntropyForensics/tools'
    }
    New-Item -ItemType Directory -Force -Path $this.ToolRoot | Out-Null
    $this.PyPath = Join-Path $this.ToolRoot 'entropy_probe_ext.py'
    [EntropyScanner]::WritePythonHelper($this.PyPath)
  }
  static [void] WritePythonHelper([string] $pyPath) {
    $py = @'
import os, sys, argparse, json, math, mimetypes, hashlib
import numpy as np
from PIL import Image
import cv2
from skimage.filters.rank import entropy as rank_entropy
from skimage.morphology import disk
from skimage.color import rgb2ycbcr

# Try MediaPipe; fallback to Haar if unavailable
try:
    import mediapipe as mp  # MediaPipe Face Detection
    MP_AVAILABLE = True
except Exception:
    MP_AVAILABLE = False
    mp = None

# ---------- Utils ----------
def shannon_from_hist(hist):
    p = hist.astype(np.float64)
    p = p / (p.sum() + 1e-12)
    nz = p[p > 0]
    return float(-(nz*np.log2(nz)).sum())

def js_divergence(p, q):
    p = p.astype(np.float64); q = q.astype(np.float64)
    p /= (p.sum()+1e-12); q /= (q.sum()+1e-12)
    m = 0.5*(p+q)
    def kl(a,b):
        mask = (a>0) & (b>0)
        return float((a[mask]*np.log2(a[mask]/b[mask])).sum())
    return 0.5*kl(p,m) + 0.5*kl(q,m)

def local_entropy_u8(u8, radius):
    return rank_entropy(u8, disk(radius))

def to_gray_u8(bgr): return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

def edge_mask(u8):
    med = np.median(u8)
    low = int(max(0, 0.66*med)); high = int(min(255, 1.33*med))
    e = cv2.Canny(u8, low, high); return (e>0)

def resize_max_dim(bgr, max_dim):
    if max_dim <= 0: return bgr, 1.0
    h, w = bgr.shape[:2]
    m = max(h, w)
    if m <= max_dim: return bgr, 1.0
    scale = max_dim / float(m)
    bgr2 = cv2.resize(bgr, (int(w*scale), int(h*scale)), interpolation=cv2.INTER_AREA)
    return bgr2, scale

# ---------- JPEG DCT/Benford/QT ----------
def benford_chi2(vals):
    vals = np.abs(vals).ravel()
    vals = vals[vals > 1e-6]
    if vals.size == 0: return 0.0
    ld = np.floor(vals / (10**np.floor(np.log10(vals)))).astype(int)
    ld = ld[(ld>=1)&(ld<=9)]
    if ld.size == 0: return 0.0
    obs = np.bincount(ld, minlength=10)[1:].astype(np.float64); obs /= (obs.sum()+1e-12)
    ben = np.array([np.log10(1+1/d) for d in range(1,9+1)], dtype=np.float64)
    return float(((obs - ben)**2 / (ben+1e-12)).sum())

def dct_block_features(gray_u8):
    H, W = gray_u8.shape
    H8, W8 = H//8*8, W//8*8
    img = gray_u8[:H8,:W8].astype(np.float32) - 128.0
    blocks = []
    for y in range(0, H8, 8):
        for x in range(0, W8, 8):
            blocks.append(cv2.dct(img[y:y+8, x:x+8]))
    D = np.stack(blocks)  # [N,8,8]
    # bands (simple rings)
    idx = np.arange(64).reshape(8,8)
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
    band_feats=[]
    Df = D.reshape(-1,64)
    for b in bands:
        ids = [idx[i,j] for (i,j) in b if not (i==0 and j==0)]
        vals = np.abs(Df[:, ids]).ravel()
        hist,_ = np.histogram(vals, bins=64, range=(0,255))
        band_feats.append(shannon_from_hist(hist))
    ben = benford_chi2(np.abs(D[:,1:,1:]))
    return {'dct_band_entropy': band_feats, 'benford_chi2': ben}

def jpeg_qtables(path):
    try:
        with Image.open(path) as im:
            if im.format != 'JPEG': return {'is_jpeg': False}
            qt = getattr(im, 'quantization', None)
            if not qt: return {'is_jpeg': True, 'qtables': None}
            tables = []
            for k in sorted(qt.keys()):
                tables.append(list(qt[k]))
            flat = np.array([x for t in tables for x in t], dtype=np.int32)
            h = hashlib.sha1(flat.tobytes()).hexdigest()
            return {'is_jpeg': True, 'qtables': tables, 'qt_hash': h, 'qt_mean': float(np.mean(flat)), 'qt_std': float(np.std(flat))}
    except Exception:
        return {'is_jpeg': False}

# ---------- Face Detection (MediaPipe → Haar fallback) ----------
_mp_fd = None
def get_face_detector():
    global _mp_fd
    if MP_AVAILABLE:
        if _mp_fd is None:
            _mp_fd = mp.solutions.face_detection.FaceDetection(model_selection=1, min_detection_confidence=0.5)
        return _mp_fd, 'mediapipe'
    else:
        return None, 'haar'

def find_faces(bgr):
    fd, tag = get_face_detector()
    if tag == 'mediapipe':
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        res = fd.process(rgb)
        boxes=[]
        if res.detections:
            for d in res.detections:
                bb = d.location_data.relative_bounding_box
                x = max(0,int(bb.xmin * w)); y = max(0,int(bb.ymin * h))
                ww = int(bb.width * w); hh = int(bb.height * h)
                if ww>0 and hh>0:
                    boxes.append((x,y,ww,hh))
        return boxes, tag
    else:
        cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        faces = cascade.detectMultiScale(gray, 1.1, 5, flags=cv2.CASCADE_SCALE_IMAGE, minSize=(48,48))
        boxes = [] if faces is None else [(int(x),int(y),int(w),int(h)) for (x,y,w,h) in faces]
        return boxes, tag

# ---------- Pixel/Temporal/Byte Features ----------
def frame_entropy_features(frame_bgr, radius, face_roi=False, min_ring_px=10):
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    ycbcr = rgb2ycbcr(rgb).astype(np.uint8)
    Y,Cb,Cr = [ycbcr[...,i] for i in range(3)]
    feats={}; chE={}
    for name,ch in [('Y',Y),('Cb',Cb),('Cr',Cr)]:
        E = local_entropy_u8(ch, radius); chE[name]=E
        feats[f'{name}_E_mean'] = float(E.mean()); feats[f'{name}_E_std'] = float(E.std())
        hist,_ = np.histogram(E, bins=32, range=(0,8)); feats[f'{name}_E_hist']=hist.tolist()
    feats['JS_Y_Cb']=js_divergence(np.array(feats['Y_E_hist']), np.array(feats['Cb_E_hist']))
    feats['JS_Y_Cr']=js_divergence(np.array(feats['Y_E_hist']), np.array(feats['Cr_E_hist']))
    u8 = to_gray_u8(frame_bgr)
    em = edge_mask(u8); fm = ~em; Ey = chE['Y']
    if em.any() and fm.any():
        feats['E_edge_mean']=float(Ey[em].mean()); feats['E_flat_mean']=float(Ey[fm].mean())
        feats['E_edge_flat_ratio']=float((Ey[em].mean()+1e-6)/(Ey[fm].mean()+1e-6))
    else:
        feats['E_edge_mean']=feats['E_flat_mean']=feats['E_edge_flat_ratio']=1.0
    mu,sd = Ey.mean(), Ey.std()+1e-9
    feats['hotspot_frac'] = float(((Ey-mu)/sd > 2.5).mean())

    roi = {}
    faces = []
    det_tag = None
    if face_roi:
        faces, det_tag = find_faces(frame_bgr)
        if len(faces)>0:
            x,y,w,h = sorted(faces, key=lambda r: r[2]*r[3], reverse=True)[0]
            roi['face']=[int(x),int(y),int(w),int(h)]
            exp = 0.3
            rx0=max(0,int(x - exp*w)); ry0=max(0,int(y - exp*h))
            rx1=min(Ey.shape[1], int(x+w*(1+exp))); ry1=min(Ey.shape[0], int(y+h*(1+exp)))
            # enforce a minimal ring width
            rx0 = max(0, min(rx0, x - min_ring_px)); ry0 = max(0, min(ry0, y - min_ring_px))
            rx1 = min(Ey.shape[1], max(rx1, x+w + min_ring_px)); ry1 = min(Ey.shape[0], max(ry1, y+h + min_ring_px))
            ring = np.zeros_like(Ey, bool)
            ring[ry0:ry1,rx0:rx1]=True; ring[y:y+h,x:x+w]=False
            faceE = Ey[y:y+h, x:x+w]; bkgE = Ey[ring]
            if faceE.size>0 and bkgE.size>0:
                roi['face_E_mean']=float(faceE.mean()); roi['bkg_E_mean']=float(bkgE.mean())
                roi['face_bkg_E_delta']=float(roi['face_E_mean']-roi['bkg_E_mean'])
                fmu,fsd = faceE.mean(), faceE.std()+1e-9
                roi['face_hotspot_frac']=float(((faceE-fmu)/fsd > 2.5).mean())
            feats['roi']=roi
    return feats, chE, faces, det_tag

def temporal_flicker(frames_gray):
    if len(frames_gray)<3: return {'flicker_frac':0.0,'std_p95':0.0}
    F = np.stack(frames_gray,axis=0).astype(np.float32)
    std = F.std(axis=0); thr=12.0
    return {'flicker_frac': float((std>thr).mean()), 'std_p95': float(np.percentile(std,95))}

def draw_overlay_native(orig_bgr, Ey_work, faces_work, scale_to_orig, out_path, top_p=0.02):
    H0,W0 = orig_bgr.shape[:2]
    Ey = cv2.resize(Ey_work, (W0,H0), interpolation=cv2.INTER_CUBIC)
    mu,sd = Ey.mean(), Ey.std()+1e-9
    Z = (Ey-mu)/sd
    flat = Z.ravel()
    k=max(1, int(len(flat)*max(0.001, min(0.2, top_p))))
    t = np.partition(flat, -k)[-k]
    mask = (Z>=t).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3,3), np.uint8))
    cnts,_ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    Zn = (np.clip(Z,0,5)/5.0*255).astype(np.uint8)
    heat = cv2.applyColorMap(Zn, cv2.COLORMAP_JET)
    overlay = cv2.addWeighted(orig_bgr, 0.65, heat, 0.35, 0)
    for (x,y,w,h) in faces_work or []:
        xs=int(x/scale_to_orig); ys=int(y/scale_to_orig); ws=int(w/scale_to_orig); hs=int(h/scale_to_orig)
        cv2.rectangle(overlay,(xs,ys),(xs+ws,ys+hs),(0,255,0),2)
    cv2.drawContours(overlay, cnts, -1, (0,0,255), 2)
    cv2.imwrite(out_path, overlay)
    return len(cnts)

def byte_entropy_features(path, w=2048, s=1024):
    try: data = np.fromfile(path, dtype=np.uint8)
    except Exception: 
        return {'byte_meanH':0.0,'byte_stdH':0.0,'byte_p95H':0.0,'byte_high_frac':0.0,'window':w,'stride':s}
    if data.size==0: 
        return {'byte_meanH':0.0,'byte_stdH':0.0,'byte_p95H':0.0,'byte_high_frac':0.0,'window':w,'stride':s}
    Hs=[]
    for i in range(0, len(data)-w+1, s):
        window = data[i:i+w]
        hist,_ = np.histogram(window, bins=256, range=(0,256))
        Hs.append(shannon_from_hist(hist))
    Hs = np.array(Hs) if Hs else np.array([0.0])
    return {'byte_meanH': float(Hs.mean()), 'byte_stdH': float(Hs.std()), 'byte_p95H': float(np.percentile(Hs,95)), 'byte_high_frac': float((Hs>7.5).mean()), 'window':w, 'stride':s}

def is_video(path):
    mt,_ = mimetypes.guess_type(path); return (mt or '').startswith('video')

# ---------- Main ----------
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
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    res = {'path': args.input, 'params': {'radius':args.radius, 'frame_stride':args.frame_stride, 'overlay_top_p':args.overlay_top_p, 'downscale_max':args.downscale_max, 'face_roi':bool(args.face_roi), 'jpeg_analysis':bool(args.jpeg_analysis)}, 'byte': byte_entropy_features(args.input)}
    kind = 'video' if is_video(args.input) else 'image'; res['kind']=kind

    detector_tag = None

    if kind=='image':
        orig = cv2.imread(args.input, cv2.IMREAD_COLOR)
        if orig is None: raise SystemExit("Failed to read image.")
        work, scale = resize_max_dim(orig, args.downscale_max)
        feats, chE, faces, detector_tag = frame_entropy_features(work, args.radius, args.face_roi)
        res['spatial']=feats
        if args.jpeg_analysis:
            gray = to_gray_u8(work)
            res['jpeg_dct']=dct_block_features(gray)
            res['jpeg_qt']=jpeg_qtables(args.input)
        ov = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")
        draw_overlay_native(orig, chE['Y'], faces, (scale if scale>0 else 1.0), ov, args.overlay_top_p)
        res['overlay']=ov
        res['temporal']={'flicker_frac':0.0,'std_p95':0.0}
    else:
        cap = cv2.VideoCapture(args.input)
        if not cap.isOpened(): raise SystemExit("Failed to open video.")
        frames_gray=[]; spatial=[]
        rep=None
        f=0
        while True:
            ret = cap.grab()
            if not ret: break
            if (f % args.frame_stride)==0:
                ret, frm = cap.retrieve()
                if not ret: break
                work, scale = resize_max_dim(frm, args.downscale_max)
                feats, chE, faces, detector_tag = frame_entropy_features(work, args.radius, args.face_roi)
                spatial.append(feats); frames_gray.append(to_gray_u8(work))
                rep=(frm, chE['Y'], faces, (scale if scale>0 else 1.0))
            f += 1
        cap.release()
        if not spatial: raise SystemExit("No frames sampled. Try smaller --frame_stride.")
        # aggregate scalars
        agg={}
        first=spatial[0]
        for k,v in first.items():
            if k.endswith('_hist') or k=='roi': continue
            agg[k]=float(np.mean([s[k] for s in spatial]))
        for c in ['Y','Cb','Cr']:
            hsum = np.sum([s[f'{c}_E_hist'] for s in spatial], axis=0)
            agg[f'{c}_E_hist']=hsum.tolist()
        if 'roi' in first:
            fbd = [s['roi'].get('face_bkg_E_delta',0.0) for s in spatial if 'roi' in s]
            fhf = [s['roi'].get('face_hotspot_frac',0.0) for s in spatial if 'roi' in s]
            agg['roi_mean_face_bkg_E_delta']=float(np.mean(fbd)) if fbd else 0.0
            agg['roi_mean_face_hotspot_frac']=float(np.mean(fhf)) if fhf else 0.0
        res['spatial']=agg
        res['temporal']=temporal_flicker(frames_gray)
        if rep:
            frm, Ey_work, faces_work, s = rep
            ov = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")
            draw_overlay_native(frm, Ey_work, faces_work, s, ov, args.overlay_top_p)
            res['overlay']=ov

    # --- Score fusion (0..10) ---
    sp = res.get('spatial', {}); bt = res.get('byte', {}); tp = res.get('temporal', {'flicker_frac':0.0,'std_p95':0.0})
    hotspot = min(1.0, sp.get('hotspot_frac',0.0)/0.05)
    js = max(sp.get('JS_Y_Cb',0.0), sp.get('JS_Y_Cr',0.0)); jsn = min(1.0, js/0.15)
    ratio = sp.get('E_edge_flat_ratio',1.0); r_anom = float(max(0.0, min(1.0, (ratio-1.2)/0.6)))
    flicker = min(1.0, (0.5*tp['flicker_frac'] + 0.5*max(0.0,(tp['std_p95']-8)/10)))
    bhigh = min(1.0, bt.get('byte_high_frac',0.0)/0.4)

    dct_s = 0.0; ben_s = 0.0; qt_s = 0.0
    if 'jpeg_dct' in res:
        bands = res['jpeg_dct']['dct_band_entropy']
        if bands:
            low = np.mean(bands[0:2]); high = np.mean(bands[-3:])
            dct_s = float(max(0.0, min(1.0, (high - low)/2.0)))
        ben = res['jpeg_dct'].get('benford_chi2', 0.0)
        ben_s = float(max(0.0, min(1.0, (ben-2.0)/6.0)))
    if 'jpeg_qt' in res and res['jpeg_qt'].get('is_jpeg', False):
        qtstd = res['jpeg_qt'].get('qt_std', 0.0)
        qt_s = float(max(0.0, min(1.0, abs(qtstd-20.0)/25.0)))

    weights = {'hotspot':0.28, 'js':0.18, 'temporal':0.18, 'byte':0.08, 'edge':0.08, 'dct':0.10, 'benford':0.08, 'qt':0.02}
    comps   = {'hotspot':hotspot, 'js':jsn, 'temporal':flicker, 'byte':bhigh, 'edge':r_anom, 'dct':dct_s, 'benford':ben_s, 'qt':qt_s}
    score01 = sum(weights[k]*comps[k] for k in weights.keys())
    score = round(10.0*max(0.0, min(1.0, score01)), 1)
    res['score_0_10'] = score
    res['score_components'] = {'weights':weights, 'components':comps}
    res['face_detector'] = detector_tag if detector_tag else 'none'

    out_json = os.path.join(args.outdir, os.path.basename(args.input) + "_features.json")
    with open(out_json,'w') as f: json.dump(res, f, indent=2)
    print(out_json)

if __name__=="__main__":
    main()
'@
    Set-Content -Path $pyPath -Value $py -Encoding UTF8 -Force
  }

  [EntropyScanResult] InvokeOne([string] $Path, [EntropyScanOptions] $opt) {
    if (-not (Test-Path $Path)) {
      $err = New-Object System.Management.Automation.ErrorRecord (
        (New-Object System.IO.FileNotFoundException "File not found: $Path"),
        "FileNotFound",
        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
        $Path)
      throw $err
    }
    $outDir = if ($opt.OutputDir) { $opt.OutputDir } else { Join-Path (Split-Path -Parent $Path) "entropy-output" }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    # Dependencies
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) { throw "Python 3 not found in PATH." }
    if ($opt.InstallDeps) {
      Write-Verbose "Installing/validating Python deps (user scope)…"

      $depScript = @"
import sys, subprocess
pkgs = ["numpy","opencv-python-headless","scikit-image","pillow","mediapipe"]
try:
    subprocess.check_call([sys.executable,"-m","pip","install","--user","--upgrade",*pkgs])
except Exception as e:
    print("WARN: Failed installing some packages. MediaPipe may be unavailable. "+str(e), file=sys.stderr)
"@
      & python -c $depScript
      if ($LASTEXITCODE -ne 0) { Write-Warning "Dependency install reported issues; proceeding." }

      $warnScript = @"
import sys
maj,min = sys.version_info[:2]
if (maj, min) >= (3,13):
    print("WARN: mediapipe wheels may not support Python 3.13 yet; prefer 3.10-3.12.", file=sys.stderr)
"@
      & python -c $warnScript
    }

    $pyArgs = @(
      "--input", $Path, "--outdir", $outDir,
      "--radius", $opt.Window, "--frame_stride", $opt.FrameStride,
      "--overlay_top_p", $opt.OverlayTopP,
      "--downscale_max", $opt.DownscaleMax
    )
    if ($opt.FaceROI)      { $pyArgs += @("--face_roi") }
    if ($opt.JPEGAnalysis) { $pyArgs += @("--jpeg_analysis") }

    Write-Verbose "Probing '$Path'…"
    $jsonPath = & python $this.PyPath @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "Probe failed for $Path" }
    $jsonPath = $jsonPath.Trim()
    if (-not (Test-Path $jsonPath)) { throw "Missing output: $jsonPath" }

    $res = Get-Content $jsonPath -Raw | ConvertFrom-Json

    # CSV append (safe)
    if ($opt.CsvPath) {
      $row = [pscustomobject]@{
        Path        = $res.path
        Kind        = $res.kind
        Score       = $res.score_0_10
        Overlay     = $res.overlay
        FeatureJson = $jsonPath
        HotspotFrac = ($res.spatial.hotspot_frac  | ForEach-Object { $_ }) 
        JSmax       = [Math]::Max($res.spatial.JS_Y_Cb, $res.spatial.JS_Y_Cr)
        ByteHighFrac= $res.byte.byte_high_frac
        FlickerFrac = $res.temporal.flicker_frac
        FaceDetector= $res.face_detector
      }
      $exists = Test-Path $opt.CsvPath
      try {
        if ($exists) { $row | Export-Csv -Path $opt.CsvPath -NoTypeInformation -Append }
        else         { $row | Export-Csv -Path $opt.CsvPath -NoTypeInformation }
      } catch {
        Write-Warning "Failed to write CSV '$($opt.CsvPath)': $($_.Exception.Message)"
      }
    }

    # Always return a result object
    $obj = [EntropyScanResult]::new($res.path, $res.kind, [double]$res.score_0_10, $res.overlay, $jsonPath, ($res | ConvertTo-Json -Depth 10 | ConvertFrom-Json))
    return $obj
  }
}

# endregion ======== Classes ========

function Invoke-EntropyDeepfakeScan {
<#
.SYNOPSIS
  Compute pixel/temporal/byte entropy, MediaPipe (fallback Haar) face ROI, JPEG DCT/Benford/QT features, overlay, and a 0–10 triage score.

.DESCRIPTION
  Uses scikit-image local entropy (rank.entropy, base-2) and MediaPipe Face Detection for ROI (falls back to Haar if MediaPipe unavailable).
  For JPEGs, adds DCT sub-band entropy, Benford deviation, and quantization-table fingerprinting.
  Outputs an overlay at native resolution and a JSON with raw features and per-term score components.

.PARAMETER Path
  One or more files (image/video). Accepts pipeline.

.PARAMETER OutputDir
  Where to write overlays and features. Defaults to sibling "entropy-output" per file.

.PARAMETER Window
  Local entropy radius (odd). Default 7.

.PARAMETER FrameStride
  Sample every Nth frame in videos. Default 12.

.PARAMETER OverlayTopP
  Top fraction (0–0.2) of z-scores to draw as hotspots. Default 0.02.

.PARAMETER FaceROI
  Enable face-vs-background entropy deltas and face boxes in overlay. Default: On.

.PARAMETER JPEGAnalysis
  Enable JPEG DCT/Benford/QT analysis on stills. Default: On.

.PARAMETER DownscaleMax
  Max dimension for processing (e.g., 1080). 0 = no downscale. Overlay is rendered at native res.

.PARAMETER CsvPath
  Append one CSV row per input with key fields.

.PARAMETER InstallDependencies
  Install/upgrade Python deps: numpy, opencv-python-headless, scikit-image, pillow, mediapipe.

.PARAMETER PassThru
  Emit [EntropyScanResult] objects.

.INPUTS
  System.String

.OUTPUTS
  EntropyScanResult
#>
  [OutputType([EntropyScanResult])]
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
  param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [string]$OutputDir,

    [ValidateRange(3,31)]
    [int]$Window = 7,

    [ValidateRange(1,60)]
    [int]$FrameStride = 12,

    [ValidateRange(0.001,0.2)]
    [double]$OverlayTopP = 0.02,

    [switch]$FaceROI,
    [switch]$JPEGAnalysis,

    [int]$DownscaleMax = 0,

    [string]$CsvPath,

    [switch]$InstallDependencies,
    [switch]$PassThru
  )

  begin {
    $scanner = [EntropyScanner]::new()
    $opt = [EntropyScanOptions]::new()
    $opt.OutputDir     = $OutputDir
    $opt.Window        = $Window
    $opt.FrameStride   = $FrameStride
    $opt.OverlayTopP   = $OverlayTopP
    $opt.FaceROI       = [bool]$FaceROI
    $opt.JPEGAnalysis  = [bool]$JPEGAnalysis
    $opt.DownscaleMax  = $DownscaleMax
    $opt.CsvPath       = $CsvPath
    $opt.InstallDeps   = [bool]$InstallDependencies
  }

  process {
    foreach ($p in $Path) {
      if ($PSCmdlet.ShouldProcess($p, "Entropy triage & overlay")) {
        try {
          $r = $scanner.InvokeOne($p, $opt)
          # Information stream for human-friendly output
          Write-Information ("{0}`nScore: {1}/10`nOverlay: {2}" -f $r.Path, $r.Score, $r.Overlay)
          # Return objects
          $r
        } catch {
          Write-Error -Category InvalidOperation -TargetObject $p -Message $_.Exception.Message
        }
      }
    }
  }
}

Export-ModuleMember -Function Invoke-EntropyDeepfakeScan
