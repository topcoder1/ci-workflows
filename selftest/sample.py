"""Trivial sample module so coverage-floor.yml has a real package to measure.

This is selftest scaffolding, not production code. See selftest/README.md.
"""


def add(a: int, b: int) -> int:
    return a + b


def is_positive(n: int) -> bool:
    return n > 0
