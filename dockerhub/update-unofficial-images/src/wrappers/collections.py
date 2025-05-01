from collections import defaultdict as _defaultdict


def dict_factory():
    return _defaultdict(dict)


def defaultdict():
    return _defaultdict(dict_factory)
