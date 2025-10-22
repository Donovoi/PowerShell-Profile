using namespace System.Collections.Generic
Set-StrictMode -Version Latest

# region ======== Classes (OOP) ========

class ImageScanOptions {
  [string]   $OutputDir
  [int]      $Window = 7
  [int]      $FrameStride = 12
  [double]   $OverlayTopP = 0.02
  [bool]     $FaceROI = $true
  [bool]     $JPEGAnalysis = $true
  [int]      $DownscaleMax = 0
  [string]   $CsvPath
  [bool]     $InstallDeps = $false
  [bool]     $Legend = $true       # draw legend on overlay
  [bool]     $SaveDebugMaps = $false      # save intermediate heatmaps
}

class ImageScanResult {
  [string]         $Path
  [string]         $Kind
  [double]         $Score
  [string]         $Overlay
  [string]         $FeatureJsonPath
  [pscustomobject] $Features

  ImageScanResult(
    [string]$p, [string]$k, [double]$s, [string]$ov, [string]$fj, [pscustomobject]$feat
  ) {
    $this.Path = $p
    $this.Kind = $k
    $this.Score = $s
    $this.Overlay = $ov
    $this.FeatureJsonPath = $fj
    $this.Features = $feat
  }
}

class ImageScanner {
  [string] $ToolRoot
  [string] $PyPath

  ImageScanner() {
    Set-StrictMode -Version Latest
    $RunningOnWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if ($RunningOnWindows) {
      $baseLocal = [Environment]::GetFolderPath('LocalApplicationData')
      if (-not $baseLocal -or [string]::IsNullOrWhiteSpace($baseLocal)) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not $userProfile -or [string]::IsNullOrWhiteSpace($userProfile)) {
          $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
        }
        $baseLocal = Join-Path $userProfile 'AppData\Local'
      }
      $this.ToolRoot = Join-Path $baseLocal 'ImageForensics\tools'
    }
    else {
      $homePath = [Environment]::GetFolderPath('UserProfile')
      if (-not $homePath -or [string]::IsNullOrWhiteSpace($homePath)) {
        $homePath = [Environment]::GetEnvironmentVariable('HOME', 'Process')
      }
      if (-not $homePath) {
        $homePath = '.' 
      }
      $this.ToolRoot = Join-Path $homePath '.cache/ImageForensics/tools'
    }
    New-Item -ItemType Directory -Force -Path $this.ToolRoot | Out-Null
    $this.PyPath = Join-Path $this.ToolRoot 'Image_probe_ext.py'
    [ImageScanner]::WritePythonHelper($this.PyPath)
  }

  static [void] WritePythonHelper([string] $pyPath) {
    $py = @'
import os, sys, argparse, json, math, mimetypes, hashlib
import numpy as np
from PIL import Image
import cv2
from skimage.filters.rank import entropy as rank_entropy
from skimage.morphology import disk
from skimage.color import rgb2ycbcr, rgb2hsv

# ---- Optional: MediaPipe face detector; Haar fallback
try:
    import mediapipe as mp
    MP_AVAILABLE = True
except Exception:
    MP_AVAILABLE = False
    mp = None

# ================= Utils =================
def shannon_from_hist(hist):
    p = hist.astype(np.float64); s = p.sum() + 1e-12
    p = p / s; nz = p[p>0]
    return float(-(nz*np.log2(nz)).sum())

def js_divergence(p, q):
    p = p.astype(np.float64); q = q.astype(np.float64)
    p /= (p.sum()+1e-12); q /= (q.sum()+1e-12)
    m = 0.5*(p+q)
    def kl(a,b):
        msk = (a>0) & (b>0)
        return float((a[msk]*np.log2(a[msk]/b[msk])).sum())
    return 0.5*kl(p,m) + 0.5*kl(q,m)

def local_entropy_u8(u8, r): return rank_entropy(u8, disk(r))
def to_gray_u8(bgr): return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

def edge_mask(u8):
    med = np.median(u8)
    low = int(max(0, 0.66*med)); high = int(min(255, 1.33*med))
    return (cv2.Canny(u8, low, high) > 0)

def resize_max_dim(bgr, max_dim):
    if max_dim <= 0: return bgr, 1.0
    h,w = bgr.shape[:2]; m = max(h,w)
    if m <= max_dim: return bgr, 1.0
    s = max_dim / float(m)
    return cv2.resize(bgr, (int(w*s), int(h*s)), interpolation=cv2.INTER_AREA), s

# ================= JPEG / Byte =================
def benford_chi2(vals):
    vals = np.abs(vals).ravel(); vals = vals[vals > 1e-6]
    if vals.size == 0: return 0.0
    ld = np.floor(vals / (10**np.floor(np.log10(vals)))).astype(int)
    ld = ld[(ld>=1)&(ld<=9)]
    if ld.size == 0: return 0.0
    obs = np.bincount(ld, minlength=10)[1:].astype(np.float64); obs /= (obs.sum()+1e-12)
    ben = np.array([np.log10(1+1/d) for d in range(1,10)], dtype=np.float64)
    return float(((obs-ben)**2/(ben+1e-12)).sum())

def dct_block_features(gray_u8):
    H,W = gray_u8.shape; H8,W8 = H//8*8, W//8*8
    img = gray_u8[:H8,:W8].astype(np.float32) - 128.0
    blocks=[]
    for y in range(0,H8,8):
        for x in range(0,W8,8):
            blocks.append(cv2.dct(img[y:y+8,x:x+8]))
    D = np.stack(blocks); idx = np.arange(64).reshape(8,8)
    bands = [
        [(0,1),(1,0),(1,1)],[(0,2),(2,0),(1,2),(2,1)],
        [(0,3),(3,0),(2,2),(1,3),(3,1)],[(0,4),(4,0),(1,4),(4,1),(2,3),(3,2)],
        [(2,4),(4,2),(3,3)],[(0,5),(5,0),(1,5),(5,1),(2,5),(5,2),(3,4),(4,3)],
        [(0,6),(6,0),(1,6),(6,1),(2,6),(6,2),(3,5),(5,3),(4,4)],
        [(0,7),(7,0),(1,7),(7,1),(2,7),(7,2),(3,6),(6,3),(4,5),(5,4)]
    ]
    band_feats=[]
    Df = D.reshape(-1,64)
    for b in bands:
        ids = [idx[i,j] for (i,j) in b if not (i==0 and j==0)]
        vals = np.abs(Df[:,ids]).ravel()
        hist,_ = np.histogram(vals, bins=64, range=(0,255))
        band_feats.append(shannon_from_hist(hist))
    ben = benford_chi2(np.abs(D[:,1:,1:]))
    return {'dct_band_entropy': band_feats, 'benford_chi2': ben}

def jpeg_qtables(path):
    try:
        with Image.open(path) as im:
            if im.format != 'JPEG': return {'is_jpeg': False}
            qt = getattr(im,'quantization',None)
            if not qt: return {'is_jpeg': True, 'qtables': None}
            tables=[]
            for k in sorted(qt.keys()): tables.append(list(qt[k]))
            flat = np.array([x for t in tables for x in t],dtype=np.int32)
            h = hashlib.sha1(flat.tobytes()).hexdigest()
            return {'is_jpeg': True,'qtables':tables,'qt_hash':h,
                    'qt_mean': float(np.mean(flat)), 'qt_std': float(np.std(flat))}
    except Exception:
        return {'is_jpeg': False}

# ================= Face detection =================
_mp_fd=None
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
        h,w = rgb.shape[:2]
        res = fd.process(rgb)
        boxes=[]
        if res.detections:
            for d in res.detections:
                bb = d.location_data.relative_bounding_box
                x = max(0,int(bb.xmin*w)); y = max(0,int(bb.ymin*h))
                ww = int(bb.width*w); hh = int(bb.height*h)
                if ww>0 and hh>0: boxes.append((x,y,ww,hh))
        return boxes, tag
    else:
        cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        faces = cascade.detectMultiScale(gray, 1.1, 5, flags=cv2.CASCADE_SCALE_IMAGE, minSize=(48,48))
        boxes = [] if faces is None else [(int(x),int(y),int(w),int(h)) for (x,y,w,h) in faces]
        return boxes, tag

# ================= Extra metrics (video-inspired) =================
def boundary_gradient_delta(Ey, face_xywh):
    # gradient just inside vs just outside face boundary (ring)
    if face_xywh is None: return 0.0
    x,y,w,h = face_xywh
    gy, gx = np.gradient(Ey.astype(np.float32))
    G = np.hypot(gx, gy)
    ring_out = np.zeros_like(G, dtype=bool)
    ring_in  = np.zeros_like(G, dtype=bool)
    pad=6
    y0=max(0,y-pad); y1=min(G.shape[0], y+h+pad)
    x0=max(0,x-pad); x1=min(G.shape[1], x+w+pad)
    ring_out[y0:y1, x0:x1]=True
    ring_out[y:y+h, x:x+w]=False
    ring_in[y+2:y+h-2, x+2:x+w-2]=True
    if ring_in.sum()==0 or ring_out.sum()==0: return 0.0
    return float(G[ring_in].mean() - G[ring_out].mean())

def specular_glint_consistency(bgr, face_xywh):
    # very lightweight: detect bright blobs inside face; compare L/R counts and circularity
    if face_xywh is None: return {'glint_asym':0.0,'glint_irreg':0.0}
    x,y,w,h = face_xywh
    crop = bgr[y:y+h, x:x+w]
    if crop.size==0: return {'glint_asym':0.0,'glint_irreg':0.0}
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    V = hsv[...,2]
    thr = max(200, int(V.mean()+1.2*V.std()))
    _,binv = cv2.threshold(V, thr, 255, cv2.THRESH_BINARY)
    # keep small blobs (possible highlights)
    cnts,_ = cv2.findContours(binv, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    feats=[]
    for c in cnts:
        a = cv2.contourArea(c)
        if a<4 or a>150: continue
        per = cv2.arcLength(c, True)+1e-6
        circ = 4*math.pi*a/(per*per)  # 1=circle
        M = cv2.moments(c)
        if M['m00']>0:
            cx=int(M['m10']/M['m00'])
            feats.append((cx,circ))
    if len(feats)<1: return {'glint_asym':0.0,'glint_irreg':0.0}
    # asymmetry: expect roughly one blob per eye, one on each side
    xs = [f[0] for f in feats]; left = sum(1 for v in xs if v < w//2); right = len(xs)-left
    asym = abs(left-right) / max(1.0, len(xs))
    irreg = float(np.mean([abs(1.0-f[1]) for f in feats]))  # non-circularity
    return {'glint_asym': float(asym), 'glint_irreg': float(irreg)}

# ================= Core features =================
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
    Z = (Ey-mu)/sd
    feats['hotspot_frac'] = float((Z > 2.5).mean())          # global
    faces=[]; det_tag=None; roi={}
    if face_roi:
        faces, det_tag = find_faces(frame_bgr)
        if len(faces)>0:
            x,y,w,h = sorted(faces, key=lambda r: r[2]*r[3], reverse=True)[0]
            roi['face']=[int(x),int(y),int(w),int(h)]
            faceE = Ey[y:y+h,x:x+w]; faceZ = (faceE - faceE.mean())/(faceE.std()+1e-9)
            # face-specific coverage & intensity
            roi['face_hotspot_cov'] = float((faceZ>2.0).mean())
            roi['face_hotspot_int'] = float(np.clip(faceZ[faceZ>2.0],0,None).mean() if (faceZ>2.0).any() else 0.0)
            # boundary gradient delta (inside vs outside)
            roi['boundary_grad_delta'] = boundary_gradient_delta(Ey, (x,y,w,h))
            # glint consistency (very lightweight)
            roi.update(specular_glint_consistency(frame_bgr, (x,y,w,h)))
            # background ring
            exp=0.3
            rx0=max(0,int(x-exp*w)); ry0=max(0,int(y-exp*h))
            rx1=min(Ey.shape[1], int(x+w*(1+exp))); ry1=min(Ey.shape[0], int(y+h*(1+exp)))
            rx0 = max(0, min(rx0, x - min_ring_px)); ry0 = max(0, min(ry0, y - min_ring_px))
            rx1 = min(Ey.shape[1], max(rx1, x+w + min_ring_px)); ry1 = min(Ey.shape[0], max(ry1, y+h + min_ring_px))
            ring = np.zeros_like(Ey,dtype=bool); ring[ry0:ry1,rx0:rx1]=True; ring[y:y+h,x:x+w]=False
            bkgE = Ey[ring]
            if faceE.size>0 and bkgE.size>0:
                roi['face_E_mean']=float(faceE.mean()); roi['bkg_E_mean']=float(bkgE.mean())
                roi['face_bkg_E_delta']=float(roi['face_E_mean']-roi['bkg_E_mean'])
            feats['roi']=roi
    return feats, chE, faces, det_tag, Z

def temporal_flicker(frames_gray):
    if len(frames_gray)<3: return {'flicker_frac':0.0,'std_p95':0.0}
    F = np.stack(frames_gray,axis=0).astype(np.float32)
    std = F.std(axis=0)
    return {'flicker_frac': float((std>12.0).mean()), 'std_p95': float(np.percentile(std,95))}

# ================= Overlay =================
def draw_overlay_native(orig_bgr, Z_work, faces_work, scale_to_orig, out_path, top_p=0.02, legend=True, glints=None):
    H0,W0 = orig_bgr.shape[:2]
    Z = cv2.resize(Z_work, (W0,H0), interpolation=cv2.INTER_CUBIC)
    flat = Z.ravel(); k=max(1,int(len(flat)*max(0.001, min(0.2, top_p))))
    t = np.partition(flat, -k)[-k]
    mask = (Z>=t).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3,3), np.uint8))
    cnts,_ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # heatmap (blue->red) + alpha
    Zn = (np.clip(Z,0,5)/5.0*255).astype(np.uint8)
    heat = cv2.applyColorMap(Zn, cv2.COLORMAP_JET)
    overlay = cv2.addWeighted(orig_bgr, 0.65, heat, 0.35, 0)

    # face boxes
    for (x,y,w,h) in (faces_work or []):
        xs=int(x/scale_to_orig); ys=int(y/scale_to_orig); ws=int(w/scale_to_orig); hs=int(h/scale_to_orig)
        cv2.rectangle(overlay,(xs,ys),(xs+ws,ys+hs),(0,255,0),2)

    # anomaly contours
    cv2.drawContours(overlay, cnts, -1, (0,0,255), 2)

    # optional: draw detected glints (white)
    if glints:
        for (gx,gy) in glints:
            cv2.circle(overlay,(gx,gy), 3, (255,255,255), -1)

    # legend
    if legend:
        pad=8
        box_w, box_h = 380, 110
        x0, y0 = pad, H0 - box_h - pad
        cv2.rectangle(overlay,(x0,y0),(x0+box_w,y0+box_h),(0,0,0),-1)
        cv2.rectangle(overlay,(x0,y0),(x0+box_w,y0+box_h),(200,200,200),1)
        cv2.putText(overlay,"Legend",(x0+10,y0+22), cv2.FONT_HERSHEY_SIMPLEX, 0.6,(220,220,220),1,cv2.LINE_AA)
        cv2.rectangle(overlay,(x0+10,y0+34),(x0+130,y0+54),(255,0,0),-1)
        cv2.rectangle(overlay,(x0+130,y0+34),(x0+250,y0+54),(0,0,255),-1)
        cv2.putText(overlay,"Heatmap: blue->red = rising anomaly",(x0+10,y0+75), cv2.FONT_HERSHEY_SIMPLEX, 0.5,(220,220,220),1,cv2.LINE_AA)
        cv2.putText(overlay,"Red contour = top anomalies",(x0+10,y0+93), cv2.FONT_HERSHEY_SIMPLEX, 0.5,(220,220,220),1,cv2.LINE_AA)
        cv2.putText(overlay,"Green box = detected face",(x0+10,y0+109), cv2.FONT_HERSHEY_SIMPLEX, 0.5,(220,220,220),1,cv2.LINE_AA)

    cv2.imwrite(out_path, overlay)
    # compute anomaly coverage in full image (useful for score)
    coverage = float(mask.mean())
    return len(cnts), coverage

def byte_entropy_features(path, w=2048, s=1024):
    try: data = np.fromfile(path, dtype=np.uint8)
    except Exception: data = np.array([],dtype=np.uint8)
    if data.size==0:
        return {'byte_meanH':0.0,'byte_stdH':0.0,'byte_p95H':0.0,'byte_high_frac':0.0,'window':w,'stride':s}
    Hs=[]
    for i in range(0, len(data)-w+1, s):
        hist,_ = np.histogram(data[i:i+w], bins=256, range=(0,256))
        Hs.append(shannon_from_hist(hist))
    Hs = np.array(Hs) if Hs else np.array([0.0])
    return {'byte_meanH': float(Hs.mean()), 'byte_stdH': float(Hs.std()),
            'byte_p95H': float(np.percentile(Hs,95)), 'byte_high_frac': float((Hs>7.5).mean()),
            'window':w, 'stride':s}

def is_video(path):
    mt,_ = mimetypes.guess_type(path); return (mt or '').startswith('video')

# ================= Main =================
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

    os.makedirs(args.outdir, exist_ok=True)
    res = {
        'path': args.input,
        'params': {'radius':args.radius, 'frame_stride':args.frame_stride,
                   'overlay_top_p':args.overlay_top_p, 'downscale_max':args.downscale_max,
                   'face_roi':bool(args.face_roi), 'jpeg_analysis':bool(args.jpeg_analysis),
                   'legend':bool(args.legend), 'save_debug':bool(args.save_debug)},
        'byte': byte_entropy_features(args.input)
    }
    kind = 'video' if is_video(args.input) else 'image'; res['kind']=kind
    detector_tag=None; overlay_coverage=0.0

    def score_from_components(res):
        # robust normalization + heavier weight on face hotspot coverage/intensity
        sp = res.get('spatial', {}); bt = res.get('byte', {}); tp = res.get('temporal', {'flicker_frac':0.0,'std_p95':0.0})
        hotspot = min(1.0, sp.get('hotspot_frac',0.0)/0.06)
        js = max(sp.get('JS_Y_Cb',0.0), sp.get('JS_Y_Cr',0.0)); jsn = min(1.0, js/0.12)
        ratio = sp.get('E_edge_flat_ratio',1.0); r_anom = float(max(0.0, min(1.0, (ratio-1.1)/0.5)))
        flicker = min(1.0, (0.6*tp.get('flicker_frac',0.0) + 0.4*max(0.0,(tp.get('std_p95',0.0)-8)/10)))
        bhigh = min(1.0, bt.get('byte_high_frac',0.0)/0.4)

        dct_s = ben_s = qt_s = 0.0
        if 'jpeg_dct' in res:
            bands = res['jpeg_dct'].get('dct_band_entropy',[])
            if len(bands)>0:
                low = float(np.mean(bands[0:2])); high = float(np.mean(bands[-3:]))
                dct_s = float(np.clip((high-low)/2.0, 0.0, 1.0))
            ben = res['jpeg_dct'].get('benford_chi2',0.0)
            ben_s = float(np.clip((ben-2.0)/6.0, 0.0, 1.0))
        if 'jpeg_qt' in res and res['jpeg_qt'].get('is_jpeg',False):
            qtstd = res['jpeg_qt'].get('qt_std',0.0)
            qt_s = float(np.clip(abs(qtstd-20.0)/25.0, 0.0, 1.0))

        # face-focused extras
        face_cov = sp.get('roi_mean_face_hotspot_frac', sp.get('roi',{}).get('face_hotspot_cov',0.0))
        face_int = sp.get('roi',{}).get('face_hotspot_int', 0.0)
        bgrad    = sp.get('roi',{}).get('boundary_grad_delta', 0.0)
        gl_asym  = sp.get('roi',{}).get('glint_asym', 0.0)
        gl_irreg = sp.get('roi',{}).get('glint_irreg',0.0)

        # normalize extras
        face_cov_n = min(1.0, face_cov/0.15)                 # 15% face area hotspots -> 1.0
        face_int_n = min(1.0, face_int/1.5)                  # average z>2 mean
        bgrad_n    = float(np.clip((bgrad-0.05)/0.25, 0.0, 1.0))
        glint_n    = float(np.clip(0.5*gl_asym + 0.5*min(1.0,gl_irreg/0.6), 0.0, 1.0))

        weights = { # sums to 1.0
            'face_cov':0.18, 'face_int':0.12, 'bgrad':0.08, 'glint':0.05,
            'hotspot':0.12, 'js':0.07, 'edge':0.06,
            'temporal':0.12, 'byte':0.05, 'dct':0.08, 'benford':0.05, 'qt':0.02
        }
        comps = {
            'face_cov':face_cov_n, 'face_int':face_int_n, 'bgrad':bgrad_n, 'glint':glint_n,
            'hotspot':hotspot, 'js':jsn, 'edge':r_anom,
            'temporal':flicker, 'byte':bhigh, 'dct':dct_s, 'benford':ben_s, 'qt':qt_s
        }
        score01 = sum(weights[k]*comps[k] for k in weights)
        # calibration: if overlay shows broad anomalies, lift floor a bit
        score01 = float(min(1.0, score01 + 0.15*min(1.0, res.get("overlay_coverage",0.0)/0.1)))
        return round(10.0*max(0.0, min(1.0, score01)), 1), {'weights':weights,'components':comps}

    if kind=='image':
        orig = cv2.imread(args.input, cv2.IMREAD_COLOR)
        if orig is None: raise SystemExit("Failed to read image.")
        work, scale = resize_max_dim(orig, args.downscale_max)
        feats, chE, faces, detector_tag, Z = frame_entropy_features(work, args.radius, args.face_roi)
        res['spatial']=feats
        if args.jpeg_analysis:
            gray = to_gray_u8(work)
            res['jpeg_dct']=dct_block_features(gray)
            res['jpeg_qt']=jpeg_qtables(args.input)
        ov = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")

        # pass glints to overlay (approximate: only from main face if present)
        gl_vis=[]
        if 'roi' in feats and 'face' in feats['roi']:
            x,y,w,h = feats['roi']['face']
            # recompute glints on original coordinates for drawing
            crop = orig[y:y+h, x:x+w]
            if crop.size>0:
                hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV); V=hsv[...,2]
                thr = max(200, int(V.mean()+1.2*V.std()))
                _,binv = cv2.threshold(V, thr, 255, cv2.THRESH_BINARY)
                cnts,_ = cv2.findContours(binv, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                for c in cnts:
                    a = cv2.contourArea(c)
                    if a<4 or a>150: continue
                    M=cv2.moments(c)
                    if M['m00']>0:
                        cx=int(M['m10']/M['m00'])+x; cy=int(M['m01']/M['m00'])+y
                        gl_vis.append((cx,cy))

        _, overlay_coverage = draw_overlay_native(orig, Z, faces, (scale if scale>0 else 1.0), ov,
                                                  args.overlay_top_p, legend=args.legend, glints=gl_vis)
        res['overlay']=ov; res['overlay_coverage']=overlay_coverage
        res['temporal']={'flicker_frac':0.0,'std_p95':0.0}

        # compute overall score (after overlay for coverage)
        score, scdetail = score_from_components(res)
        res['score_0_10']=score; res['score_components']=scdetail

        if args.save_debug:
            cv2.imwrite(os.path.join(args.outdir, os.path.basename(args.input) + "_Z.png"),
                        (np.clip(Z,0,5)/5.0*255).astype(np.uint8))

    else:
        cap = cv2.VideoCapture(args.input)
        if not cap.isOpened(): raise SystemExit("Failed to open video.")
        frames_gray=[]; spatial=[]; rep=None; f=0
        while True:
            ret = cap.grab()
            if not ret: break
            if (f % args.frame_stride)==0:
                ret, frm = cap.retrieve()
                if not ret: break
                work, scale = resize_max_dim(frm, args.downscale_max)
                feats, chE, faces, detector_tag, Z = frame_entropy_features(work, args.radius, args.face_roi)
                spatial.append(feats); frames_gray.append(to_gray_u8(work))
                rep=(frm, Z, faces, (scale if scale>0 else 1.0))
            f += 1
        cap.release()
        if not spatial: raise SystemExit("No frames sampled. Try smaller --frame_stride.")
        agg={}; first=spatial[0]
        for k in first.keys():
            if k.endswith('_hist') or k=='roi': continue
            agg[k]=float(np.mean([s[k] for s in spatial]))
        for c in ['Y','Cb','Cr']:
            hsum = np.sum([s[f'{c}_E_hist'] for s in spatial], axis=0)
            agg[f'{c}_E_hist']=hsum.tolist()
        if 'roi' in first:
            fbd = [s['roi'].get('face_bkg_E_delta',0.0) for s in spatial if 'roi' in s]
            fhf = [s['roi'].get('face_hotspot_cov',0.0) for s in spatial if 'roi' in s]
            fint= [s['roi'].get('face_hotspot_int',0.0) for s in spatial if 'roi' in s]
            bgrd= [s['roi'].get('boundary_grad_delta',0.0) for s in spatial if 'roi' in s]
            gasy= [s['roi'].get('glint_asym',0.0) for s in spatial if 'roi' in s]
            girr= [s['roi'].get('glint_irreg',0.0) for s in spatial if 'roi' in s]
            agg['roi_mean_face_bkg_E_delta']=float(np.mean(fbd)) if fbd else 0.0
            agg['roi_mean_face_hotspot_frac']=float(np.mean(fhf)) if fhf else 0.0
            agg['roi_mean_face_hotspot_int']=float(np.mean(fint)) if fint else 0.0
            agg['roi_mean_boundary_grad_delta']=float(np.mean(bgrd)) if bgrd else 0.0
            agg['roi_mean_glint_asym']=float(np.mean(gasy)) if gasy else 0.0
            agg['roi_mean_glint_irreg']=float(np.mean(girr)) if girr else 0.0
        res['spatial']=agg
        res['temporal']=temporal_flicker(frames_gray)

        if rep:
            frm, Z_work, faces_work, s = rep
            ov = os.path.join(args.outdir, os.path.basename(args.input) + "_overlay.png")
            _, overlay_coverage = draw_overlay_native(frm, Z_work, faces_work, s, ov,
                                                      args.overlay_top_p, legend=args.legend)
            res['overlay']=ov; res['overlay_coverage']=overlay_coverage

        score, scdetail = score_from_components(res)
        res['score_0_10']=score; res['score_components']=scdetail

    out_json = os.path.join(args.outdir, os.path.basename(args.input) + "_features.json")
    with open(out_json,'w') as f: json.dump(res, f, indent=2)
    print(out_json)

if __name__=="__main__":
    main()
'@
    Set-Content -Path $pyPath -Value $py -Encoding UTF8 -Force
  }

  [ImageScanResult] InvokeOne([string] $Path, [ImageScanOptions] $opt) {
    Set-StrictMode -Version Latest

    if (-not (Test-Path $Path)) {
      $err = New-Object System.Management.Automation.ErrorRecord (
        (New-Object System.IO.FileNotFoundException "File not found: $Path"),
        'FileNotFound',
        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
        $Path
      )
      throw $err
    }

    $outDir = if ($opt.OutputDir) {
      $opt.OutputDir 
    }
    else {
      Join-Path (Split-Path -Parent $Path) 'Image-output' 
    }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pyCmd) {
      throw 'Python 3 not found in PATH.' 
    }

    if ($opt.InstallDeps) {
      Write-Verbose 'Installing/validating Python deps (user scope)…'
      $depScript = @'
import sys, subprocess
pkgs = ["numpy","opencv-python-headless","scikit-image","pillow","mediapipe"]
try:
    subprocess.check_call([sys.executable,"-m","pip","install","--user","--upgrade",*pkgs])
except Exception as e:
    print("WARN: Failed installing some packages. MediaPipe may be unavailable. "+str(e), file=sys.stderr)
'@
      & python -c $depScript
      if ($global:LASTEXITCODE -ne 0) {
        Write-Warning 'Dependency install reported issues; proceeding.' 
      }
      $warnScript = @'
import sys
maj,min = sys.version_info[:2]
if (maj, min) >= (3,13):
    print("WARN: mediapipe wheels may not support Python 3.13 yet; prefer 3.10-3.12.", file=sys.stderr)
'@
      & python -c $warnScript
    }

    $pyArgs = @(
      '--input', $Path, '--outdir', $outDir,
      '--radius', $opt.Window, '--frame_stride', $opt.FrameStride,
      '--overlay_top_p', $opt.OverlayTopP,
      '--downscale_max', $opt.DownscaleMax
    )
    if ($opt.FaceROI) {
      $pyArgs += @('--face_roi') 
    }
    if ($opt.JPEGAnalysis) {
      $pyArgs += @('--jpeg_analysis') 
    }
    if ($opt.Legend) {
      $pyArgs += @('--legend') 
    }
    if ($opt.SaveDebugMaps) {
      $pyArgs += @('--save_debug') 
    }

    Write-Verbose "Probing '$Path'…"
    $jsonPath = & python $this.PyPath @pyArgs
    if ($global:LASTEXITCODE -ne 0) {
      throw "Probe failed for $Path" 
    }
    $jsonPath = $jsonPath.Trim()
    if (-not (Test-Path $jsonPath)) {
      throw "Missing output: $jsonPath" 
    }

    $res = Get-Content $jsonPath -Raw | ConvertFrom-Json

    if ($opt.CsvPath) {
      $row = [pscustomobject]@{
        Path         = $res.path
        Kind         = $res.kind
        Score        = $res.score_0_10
        Overlay      = $res.overlay
        FeatureJson  = $jsonPath
        HotspotFrac  = ($res.spatial.hotspot_frac | ForEach-Object { $_ })
        FaceHotCov   = ($res.spatial.roi_mean_face_hotspot_frac, $res.spatial.roi.face_hotspot_cov | Where-Object { $_ -ne $null } | Select-Object -First 1)
        ByteHighFrac = $res.byte.byte_high_frac
        FlickerFrac  = $res.temporal.flicker_frac
        FaceDetector = $res.face_detector
      }
      $exists = Test-Path $opt.CsvPath
      try {
        if ($exists) {
          $row | Export-Csv -Path $opt.CsvPath -NoTypeInformation -Append 
        }
        else {
          $row | Export-Csv -Path $opt.CsvPath -NoTypeInformation 
        }
      }
      catch {
        Write-Warning "Failed to write CSV '$($opt.CsvPath)': $($_.Exception.Message)"
      }
    }

    $obj = [ImageScanResult]::new(
      $res.path, $res.kind, [double]$res.score_0_10,
      $res.overlay, $jsonPath, ($res | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    )
    return $obj
  }
}

# endregion ======== Classes ========

function Invoke-DeepfakeScan {
  <#
.SYNOPSIS
  Pixel/temporal/byte entropy + JPEG forensics with face-focused extras, overlay legend, and a calibrated 0–10 score.

.DESCRIPTION
  - Local entropy (Y, Cb, Cr) and JS-divergence between channels
  - Edge/flat entropy ratio
  - Optional JPEG DCT-band entropy, Benford deviation, and QT fingerprint
  - Temporal flicker (videos)
  - NEW: face hotspot coverage + intensity, boundary-gradient mismatch, simple specular-glint consistency
  - Overlay: heatmap (blue→red), red anomaly contours, green face box, optional white dots for glints, with legend
  - Score: fused & calibrated so strong face anomalies lift the score appropriately

.PARAMETER Path
  One or more files (image/video). Accepts pipeline.

.PARAMETER OutputDir
  Directory for overlays and JSON features (default: sibling "entropy-output").

.PARAMETER Window
  Local-entropy radius (odd). Default 7.

.PARAMETER FrameStride
  Sample every Nth frame in videos. Default 12.

.PARAMETER OverlayTopP
  Top fraction of z-scores used for red anomaly contours. Default 0.02.

.PARAMETER FaceROI
  Enable face-vs-background analysis and face-box overlay.

.PARAMETER JPEGAnalysis
  Enable JPEG DCT/Benford/QT analysis on stills.

.PARAMETER DownscaleMax
  Max dimension to process (0 = no downscale).

.PARAMETER CsvPath
  Append key fields per input to CSV.

.PARAMETER InstallDependencies
  Install/upgrade Python deps (user scope).

.PARAMETER Legend
  Draw overlay legend box. On by default.

.PARAMETER SaveDebugMaps
  Write intermediate anomaly map (Z) to disk.
#>
  [OutputType([ImageScanResult])]
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
  param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [string]$OutputDir,

    [ValidateRange(3, 31)]
    [int]$Window = 7,

    [ValidateRange(1, 60)]
    [int]$FrameStride = 12,

    [ValidateRange(0.001, 0.2)]
    [double]$OverlayTopP = 0.02,

    [switch]$FaceROI,
    [switch]$JPEGAnalysis,

    [int]$DownscaleMax = 0,

    [string]$CsvPath,

    [switch]$InstallDependencies,

    [switch]$Legend,
    [switch]$SaveDebugMaps
  )

  begin {
    Set-StrictMode -Version Latest
    $scanner = [ImageScanner]::new()
    $opt = [ImageScanOptions]::new()
    $opt.OutputDir = $OutputDir
    $opt.Window = $Window
    $opt.FrameStride = $FrameStride
    $opt.OverlayTopP = $OverlayTopP
    $opt.FaceROI = [bool]$FaceROI
    $opt.JPEGAnalysis = [bool]$JPEGAnalysis
    $opt.DownscaleMax = $DownscaleMax
    $opt.CsvPath = $CsvPath
    $opt.InstallDeps = [bool]$InstallDependencies
    $opt.Legend = [bool]$Legend
    $opt.SaveDebugMaps = [bool]$SaveDebugMaps
  }

  process {
    foreach ($p in $Path) {
      if ($PSCmdlet.ShouldProcess($p, 'Image triage & overlay')) {
        try {
          $r = $scanner.InvokeOne($p, $opt)
          Write-Information ("{0}`nScore: {1}/10`nOverlay: {2}" -f $r.Path, $r.Score, $r.Overlay)
          $r
        }
        catch {
          Write-Error -Category InvalidOperation -TargetObject $p -Message $_.Exception.Message
        }
      }
    }
  }
}

Export-ModuleMember -Function Invoke-DeepfakeScan
