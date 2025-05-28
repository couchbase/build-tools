from collections import defaultdict as _defaultdict


def dict_factory():
    return _defaultdict(dict)


def defaultdict(factory=None):
    if factory is None:
        return _defaultdict(dict_factory)
    else:
        return _defaultdict(factory)
