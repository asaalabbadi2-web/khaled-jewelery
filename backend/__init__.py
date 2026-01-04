"""Backend package.

Keep this module side-effect free so importing `backend.*` (e.g. via Gunicorn)
does not eagerly import application modules that may depend on runtime
configuration.
"""
