#!/usr/bin/env python3
"""Starts the encode review worker. systemd runs this file (encode-review/systemd/)."""

import sys

from encode_review.worker import main

if __name__ == "__main__":
    sys.exit(main())
