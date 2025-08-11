from fastapi import FastAPI
from pydantic import BaseModel
from typing import Dict, Any

app = FastAPI()

class AnalyzeRequest(BaseModel):
    image_url: str

@app.get("/healthz")
def healthz() -> Dict[str, bool]:
    return {"ok": True}

@app.post("/analyze")
def analyze(req: AnalyzeRequest) -> Dict[str, Any]:
    return {
        "ok": True,
        "items": [
            {
                "label": "dummy-item",
                "confidence": 0.99,
                "bbox": [10, 20, 100, 200],
            }
        ],
        "image_url": req.image_url,
    }