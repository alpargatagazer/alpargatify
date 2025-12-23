import os

def get_secret(secret_name, default=None):
    """
    Reads a secret from Docker secrets location (/run/secrets/<secret_name>)
    or falls back to environment variable.
    """
    secret_path = f"/run/secrets/{secret_name}"
    try:
        with open(secret_path, "r") as f:
            return f.read().strip()
    except IOError:
        return os.environ.get(secret_name.upper(), default)
