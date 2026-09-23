import json
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def smoke_path() -> Path:
    return FIXTURES / "smoke.json"


@pytest.fixture
def smoke_data(smoke_path: Path) -> dict:
    return json.loads(smoke_path.read_text(encoding="utf-8"))
