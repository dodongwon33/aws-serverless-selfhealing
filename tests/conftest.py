import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # src/에 __pycache__가 생기면 Terraform zip 해시가 흔들린다

ROOT = Path(__file__).resolve().parents[1]
for sub in ("app", "remediation", "killswitch"):
    sys.path.insert(0, str(ROOT / "src" / sub))

os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-2")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("TABLE_NAME", "selfheal-test-items")
os.environ.setdefault("POWERTOOLS_TRACE_DISABLED", "true")
os.environ.setdefault("POWERTOOLS_SERVICE_NAME", "selfheal-test")
