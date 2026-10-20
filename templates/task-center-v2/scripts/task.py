#!/usr/bin/env python3
"""File-based entry point shared by both shell clients."""
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from taskcore.cli import main

if __name__ == '__main__':
    raise SystemExit(main())
