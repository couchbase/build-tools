import logging

# Set up logging and handler
logger = logging.getLogger('onboard_offboard')
logger.setLevel(logging.INFO)
formatter = logging.Formatter('%(levelname)s: %(message)s')
handler = logging.StreamHandler()
handler.setFormatter(formatter)
handler.setLevel(logging.INFO)
logger.addHandler(handler)
