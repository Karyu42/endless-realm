#!/usr/bin/env python3
"""Fail unless a GUT JUnit XML file exists, parses, and reports >0 tests with no failures/errors.

Usage: check-junit.py <junit.xml>
GUT's CLI can exit 0 without running anything (e.g. classes not imported), so the
exit code alone is not trusted.
"""
import os
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
if not os.path.isfile(path):
    print(f"::error::JUnit XML not found at {path}: GUT did not run or did not write results")
    sys.exit(1)
try:
    root = ET.parse(path).getroot()
except ET.ParseError as exc:
    print(f"::error::JUnit XML at {path} does not parse: {exc}")
    sys.exit(1)

cases = list(root.iter("testcase"))
failures = sum(1 for c in cases if c.find("failure") is not None)
errors = sum(1 for c in cases if c.find("error") is not None)
skipped = sum(1 for c in cases if c.find("skipped") is not None)
total = len(cases)
if total == 0:
    try:
        total = int(root.get("tests", "0"))
    except ValueError:
        total = 0

summary = f"GUT results: {total} tests, {failures} failures, {errors} errors, {skipped} skipped/pending"
print(summary)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
        fh.write(f"### {summary}\n")

if total == 0:
    print("::error::0 tests ran. CI requires at least one GUT test.")
    sys.exit(1)
if failures or errors:
    print(f"::error::{failures} failing and {errors} erroring GUT tests")
    sys.exit(1)
