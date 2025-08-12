from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Dict, Any, List, Optional
import io
import os
import time
import json
import requests
from PIL import Image

try:
    import numpy as np
except Exception:  # pragma: no cover
    np = None  # type: ignore

# Optional heavy deps (graceful fallback)
try:
    import cv2  # type: ignore
except Exception:
    cv2 = None  # type: ignore

try:
    from ultralytics import YOLO  # type: ignore
except Exception:
    YOLO = None  # type: ignore

try:
    from paddleocr import PaddleOCR  # type: ignore
except Exception:
    PaddleOCR = None  # type: ignore

try:
    import boto3  # type: ignore
    from botocore.client import Config as BotoConfig  # type: ignore
except Exception:
    boto3 = None  # type: ignore

APP_VERSION = os.environ.get("CV_ANALYZER_VERSION", "0.2.0-phase2")

app = FastAPI()


class AnalyzeRequest(BaseModel):
    image_url: str
    max_items: int = 12


@app.get("/healthz")
def healthz() -> Dict[str, bool]:
    return {"ok": True}


@app.get("/version")
def version() -> Dict[str, str]:
    return {"version": APP_VERSION}


@app.post("/analyze")
def analyze(req: AnalyzeRequest) -> Dict[str, Any]:
    # Fetch image
    try:
        r = requests.get(req.image_url, timeout=20)
        r.raise_for_status()
        image = Image.open(io.BytesIO(r.content)).convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to load image: {e}")

    width, height = image.size

    # Try detection pipeline; if unavailable, produce a simple rectangular item
    items: List[Dict[str, Any]] = []

    used_fallback = False

    if YOLO is not None and cv2 is not None and np is not None:
        try:
            # Attempt to load small segment model; download if needed
            model = YOLO(os.environ.get("YOLO_SEG_WEIGHTS", "yolov8n-seg.pt"))
            # Run inference
            result_list = model.predict(np.array(image), verbose=False)
            for res in result_list:
                # res.masks and res.boxes may be present
                if len(items) >= req.max_items:
                    break
                if getattr(res, "boxes", None) is None:
                    continue
                for bidx in range(len(res.boxes)):
                    if len(items) >= req.max_items:
                        break
                    box = res.boxes[bidx].xyxy[0].tolist()  # [x1,y1,x2,y2]
                    x1, y1, x2, y2 = [int(max(0, v)) for v in box]
                    # Polygon approximation as rectangle for now
                    polygon = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
                    crop = image.crop((x1, y1, x2, y2))
                    crop_url = _maybe_upload_crop(crop)
                    ocr_raw, ocr_conf = _run_ocr_best(crop)
                    items.append({
                        "id": f"det-{len(items)+1}",
                        "polygon": polygon,
                        "bbox": [x1, y1, x2 - x1, y2 - y1],
                        "angle_deg": 0,
                        "crop_url": crop_url,
                        "ocr": {"raw": ocr_raw, "conf": ocr_conf, "words": []},
                    })
        except Exception:
            used_fallback = True
    else:
        used_fallback = True

    if used_fallback:
        # Minimal 1-item fallback centered box
        cx, cy = width // 2, height // 2
        bw, bh = max(50, width // 4), max(50, height // 4)
        x1, y1 = max(0, cx - bw // 2), max(0, cy - bh // 2)
        x2, y2 = min(width, x1 + bw), min(height, y1 + bh)
        polygon = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
        crop = image.crop((x1, y1, x2, y2))
        crop_url = _maybe_upload_crop(crop)
        ocr_raw, ocr_conf = _run_ocr_best(crop)
        items.append({
            "id": "det-1",
            "polygon": polygon,
            "bbox": [x1, y1, x2 - x1, y2 - y1],
            "angle_deg": 0,
            "crop_url": crop_url,
            "ocr": {"raw": ocr_raw, "conf": ocr_conf, "words": []},
        })

    return {
        "image": {"width": width, "height": height},
        "items": items,
    }


def _run_ocr_best(crop_img: Image.Image) -> (str, float):
    # Try simple OCR via PaddleOCR if available; else return dummy
    if PaddleOCR is not None and np is not None:
        try:
            ocr = PaddleOCR(use_angle_cls=True, lang="en")
            arr = np.array(crop_img)
            result = ocr.ocr(arr)
            texts: List[str] = []
            confidences: List[float] = []
            for line in result or []:
                for _box, (txt, conf) in line or []:
                    texts.append(txt)
                    try:
                        confidences.append(float(conf))
                    except Exception:
                        pass
            if texts:
                avg_conf = float(sum(confidences) / max(1, len(confidences))) if confidences else 0.5
                return (" ".join(texts)[:256], avg_conf)
        except Exception:
            pass
    return ("unknown title", 0.0)


def _maybe_upload_crop(crop_img: Image.Image) -> Optional[str]:
    bucket = os.environ.get("AWS_BUCKET")
    endpoint = os.environ.get("AWS_ENDPOINT")
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    access = os.environ.get("AWS_ACCESS_KEY_ID")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if not all([bucket, endpoint, access, secret]) or boto3 is None:
        return None
    try:
        buf = io.BytesIO()
        crop_img.save(buf, format="JPEG", quality=90)
        buf.seek(0)
        key = f"crops/{int(time.time())}-{os.getpid()}-{int(time.time_ns() % 1e6)}.jpg"
        s3 = boto3.client(
            "s3",
            region_name=region,
            endpoint_url=endpoint,
            aws_access_key_id=access,
            aws_secret_access_key=secret,
            config=BotoConfig(s3={"addressing_style": "path"}),
        )
        s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue(), ContentType="image/jpeg")
        url = f"{endpoint}/{bucket}/{key}".replace("https://", "https://")
        return url
    except Exception:
        return None