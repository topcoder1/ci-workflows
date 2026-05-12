from selftest.sample import add, is_positive


def test_add():
    assert add(1, 2) == 3
    assert add(-1, 1) == 0


def test_is_positive():
    assert is_positive(5) is True
    assert is_positive(0) is False
    assert is_positive(-3) is False
