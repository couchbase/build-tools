import configparser
import os
import sys
from api import logger


class API:
    """Superclass with shared factory method

    This is just used to avoid doubling up on how the config file is ingested
    """
    @classmethod
    def from_config_file(cls, config_path, section):
        if not os.path.exists(config_path):
            logger.error(f'Configuration file {config_path} missing!')
            sys.exit(1)
        config = configparser.ConfigParser()
        config.read(config_path)
        if section not in config:
            logger.error(
                f'Invalid config file "{config_path}" (missing {section} '
                'section)')
            sys.exit(1)
        response = {}
        for item in config.items(section):
            response[item[0]] = item[1]
        return response
