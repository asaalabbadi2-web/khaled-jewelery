from __future__ import annotations

import os


def get_repo_root() -> str:
	# backend/.. => repo root
	return os.path.realpath(os.path.join(os.path.dirname(__file__), '..'))


def get_env_production_path() -> str:
	return os.path.join(get_repo_root(), '.env.production')


def is_setup_locked() -> bool:
	"""Setup is considered locked once .env.production exists.

	Rationale: the user explicitly requested that re-opening setup requires
	manual deletion of the setup file.
	"""
	try:
		return os.path.exists(get_env_production_path())
	except Exception:
		return False
