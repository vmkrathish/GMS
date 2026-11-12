# Database URL resolution (env_config.py). Pure logic — no database needed.
import importlib

import pytest

import app.core.env_config as env_config

PLACEHOLDER = "postgresql+psycopg2://postgres.<REF>:<PW>@pooler.example:5432/postgres"


@pytest.mark.parametrize("raw,expected", [
    ("postgresql://u:p@h:5432/db", "postgresql+psycopg2://u:p@h:5432/db"),
    ("postgres://u:p@h:5432/db", "postgresql+psycopg2://u:p@h:5432/db"),
    ("postgresql+psycopg2://u:p@h/db", "postgresql+psycopg2://u:p@h/db"),
    ("  postgresql://u:p@h/db\n", "postgresql+psycopg2://u:p@h/db"),
])
def test_normalize_db_url(raw, expected):
    assert env_config.normalize_db_url(raw) == expected


def test_env_var_wins_and_is_normalized(monkeypatch):
    monkeypatch.setattr(env_config, "ONLINE_DATABASE_URL", "postgresql://file:pw@h/db")
    monkeypatch.setenv("DATABASE_URL", "postgresql://env:pw@pooler:5432/postgres")
    url, source = env_config._resolve_online_url()
    assert url == "postgresql+psycopg2://env:pw@pooler:5432/postgres"
    assert source == "env:DATABASE_URL"


def test_placeholder_without_env_var_fails_loudly(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setattr(env_config, "ONLINE_DATABASE_URL", PLACEHOLDER)
    with pytest.raises(RuntimeError, match="DATABASE_URL"):
        env_config._resolve_online_url()


def test_legacy_hardcoded_url_still_works_with_warning(monkeypatch, caplog):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setattr(env_config, "ONLINE_DATABASE_URL", "postgresql://u:real@h/db")
    url, source = env_config._resolve_online_url()
    assert url == "postgresql+psycopg2://u:real@h/db"
    assert "legacy" in source
    assert "hard-coded" in caplog.text


def test_dotenv_file_cannot_override(tmp_path, monkeypatch):
    # The original "one switch" rule: a stray .env must not redirect the DB.
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.chdir(tmp_path)
    (tmp_path / ".env").write_text("DATABASE_URL=mysql://stray:x@old/db\n")
    from app.core.config import Settings
    assert "mysql" not in Settings().DATABASE_URL


def test_resulting_url_loads_with_installed_driver():
    # Guards the SQLAlchemy 2.1 'No module named psycopg' crash.
    from sqlalchemy import create_engine
    url = env_config.normalize_db_url("postgresql://u:p@h:5432/db")
    create_engine(url)  # must not raise ModuleNotFoundError
