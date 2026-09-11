"""Local config/runtime directories for the YT Widget backend."""

from __future__ import annotations

import os
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "ytwidget"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "ytwidget"


def config_dir() -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_DIR.chmod(0o700)
    return CONFIG_DIR


def cache_dir() -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.chmod(0o700)
    return CACHE_DIR
