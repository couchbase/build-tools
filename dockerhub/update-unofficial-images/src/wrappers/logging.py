import logging


def setup_logging(level: int=logging.DEBUG) -> None:
    logging.basicConfig(level=level,
                        format='%(asctime)s - %(message)s',
                        datefmt='%Y-%m-%d %H:%M:%S',
    )
