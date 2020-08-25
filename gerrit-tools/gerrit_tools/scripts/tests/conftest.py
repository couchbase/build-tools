import os
from subprocess import Popen, PIPE

def reset_checkout():
    process = Popen(['repo', 'sync', '-j8'], stdout=PIPE, stderr=PIPE, cwd=os.getenv('source_path'))
    stdout, stderr = process.communicate()
