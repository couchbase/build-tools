import logging
import logging.handlers
import datetime
import socket
import os

pid = os.getpid()

logger = logging.getLogger('repo_upload')

if not logger.handlers:
    # Console handler
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.DEBUG)
    logger.addHandler(console_handler)

    # Syslog handler
    try:
        if(os.environ['SYSLOG_HOST'] and os.environ['SYSLOG_PORT']):
            class StrippedFormatter(logging.Formatter):
                def format(self, record):
                    record.msg = record.msg.strip()
                    return super(StrippedFormatter, self).format(record)

            syslog_formatter = StrippedFormatter(
                f'%(asctime)s.%(msecs)03d {socket.gethostname()} %(name)s [{pid}]: [%(levelname)s] %(message)s', "%b %d %X")
            syslog_handler = logging.handlers.SysLogHandler(
                address=(os.environ['SYSLOG_HOST'], int(os.environ['SYSLOG_PORT'])))
            syslog_handler.setLevel(logging.DEBUG)
            syslog_handler.setFormatter(syslog_formatter)
            logger.addHandler(syslog_handler)
    except KeyError:
        print(
            'SYSLOG_HOST and SYSLOG_PORT environment variables not set, console logs only')
