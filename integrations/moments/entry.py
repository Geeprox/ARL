"""Signed ARL child: packaged Python only, immutable code, no source-tree escape."""
import sys
from pathlib import Path
root=Path(__file__).resolve().parent
sys.path[:0]=[str(root/'worker'),str(root/'pillow')]
from local_service import main
main()
