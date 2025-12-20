# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_data_files
from PyInstaller.utils.hooks import collect_dynamic_libs
from PyInstaller.utils.hooks import collect_submodules
from PyInstaller.utils.hooks import copy_metadata

datas = [('/usr/local/lib/python3.10/site-packages/singer/logging.conf', 'singer/')]
binaries = []
hiddenimports = ['tap_postgres', 'tap_postgres.sync_strategies', 'tap_postgres.db', 'psycopg2', 'psycopg2._psycopg', 'psycopg2.extensions']
datas += collect_data_files('tap_postgres')
datas += collect_data_files('PyInstaller')
datas += collect_data_files('aiohappyeyeballs')
datas += collect_data_files('aiohttp')
datas += collect_data_files('aiosignal')
datas += collect_data_files('altgraph')
datas += collect_data_files('ansible')
datas += collect_data_files('ansible_test')
datas += collect_data_files('argparse')
datas += collect_data_files('async_timeout')
datas += collect_data_files('attr')
datas += collect_data_files('attrs')
datas += collect_data_files('backoff')
datas += collect_data_files('backports')
datas += collect_data_files('certifi')
datas += collect_data_files('cffi')
datas += collect_data_files('chardet')
datas += collect_data_files('charset_normalizer')
datas += collect_data_files('ciso8601')
datas += collect_data_files('cryptography')
datas += collect_data_files('dateutil')
datas += collect_data_files('dpath')
datas += collect_data_files('frozenlist')
datas += collect_data_files('idna')
datas += collect_data_files('inflection')
datas += collect_data_files('jinja2')
datas += collect_data_files('joblib')
datas += collect_data_files('jsonschema')
datas += collect_data_files('markupsafe')
datas += collect_data_files('multidict')
datas += collect_data_files('packaging')
datas += collect_data_files('pidfile')
datas += collect_data_files('pip')
datas += collect_data_files('pkg_resources')
datas += collect_data_files('propcache')
datas += collect_data_files('psutil')
datas += collect_data_files('psycopg2')
datas += collect_data_files('pvectorc')
datas += collect_data_files('pycparser')
datas += collect_data_files('pyrsistent')
datas += collect_data_files('pytz')
datas += collect_data_files('pytz_deprecation_shim')
datas += collect_data_files('requests')
datas += collect_data_files('resolvelib')
datas += collect_data_files('setuptools')
datas += collect_data_files('simplejson')
datas += collect_data_files('singer')
datas += collect_data_files('six')
datas += collect_data_files('slack')
datas += collect_data_files('sqlparse')
datas += collect_data_files('strict_rfc3339')
datas += collect_data_files('tabulate')
datas += collect_data_files('tap_postgres')
datas += collect_data_files('target_postgres')
datas += collect_data_files('transform_field')
datas += collect_data_files('typing_extensions')
datas += collect_data_files('tzdata')
datas += collect_data_files('tzlocal')
datas += collect_data_files('ujson')
datas += collect_data_files('urllib3')
datas += collect_data_files('wheel')
datas += collect_data_files('yaml')
datas += collect_data_files('yarl')
datas += copy_metadata('psycopg2-binary')
datas += copy_metadata('pipelinewise-tap-postgres')
binaries += collect_dynamic_libs('psycopg2')
hiddenimports += collect_submodules('tap_postgres')
hiddenimports += collect_submodules('PyInstaller')
hiddenimports += collect_submodules('aiohappyeyeballs')
hiddenimports += collect_submodules('aiohttp')
hiddenimports += collect_submodules('aiosignal')
hiddenimports += collect_submodules('altgraph')
hiddenimports += collect_submodules('ansible_test')
hiddenimports += collect_submodules('argparse')
hiddenimports += collect_submodules('async_timeout')
hiddenimports += collect_submodules('attr')
hiddenimports += collect_submodules('attrs')
hiddenimports += collect_submodules('backoff')
hiddenimports += collect_submodules('backports')
hiddenimports += collect_submodules('certifi')
hiddenimports += collect_submodules('cffi')
hiddenimports += collect_submodules('chardet')
hiddenimports += collect_submodules('charset_normalizer')
hiddenimports += collect_submodules('ciso8601')
hiddenimports += collect_submodules('cryptography')
hiddenimports += collect_submodules('dateutil')
hiddenimports += collect_submodules('dpath')
hiddenimports += collect_submodules('frozenlist')
hiddenimports += collect_submodules('idna')
hiddenimports += collect_submodules('inflection')
hiddenimports += collect_submodules('jinja2')
hiddenimports += collect_submodules('joblib')
hiddenimports += collect_submodules('jsonschema')
hiddenimports += collect_submodules('markupsafe')
hiddenimports += collect_submodules('multidict')
hiddenimports += collect_submodules('packaging')
hiddenimports += collect_submodules('pidfile')
hiddenimports += collect_submodules('pip')
hiddenimports += collect_submodules('pkg_resources')
hiddenimports += collect_submodules('propcache')
hiddenimports += collect_submodules('psutil')
hiddenimports += collect_submodules('psycopg2')
hiddenimports += collect_submodules('pvectorc')
hiddenimports += collect_submodules('pycparser')
hiddenimports += collect_submodules('pyrsistent')
hiddenimports += collect_submodules('pytz')
hiddenimports += collect_submodules('pytz_deprecation_shim')
hiddenimports += collect_submodules('requests')
hiddenimports += collect_submodules('resolvelib')
hiddenimports += collect_submodules('setuptools')
hiddenimports += collect_submodules('simplejson')
hiddenimports += collect_submodules('singer')
hiddenimports += collect_submodules('six')
hiddenimports += collect_submodules('slack')
hiddenimports += collect_submodules('sqlparse')
hiddenimports += collect_submodules('strict_rfc3339')
hiddenimports += collect_submodules('tabulate')
hiddenimports += collect_submodules('tap_postgres')
hiddenimports += collect_submodules('target_postgres')
hiddenimports += collect_submodules('transform_field')
hiddenimports += collect_submodules('typing_extensions')
hiddenimports += collect_submodules('tzdata')
hiddenimports += collect_submodules('tzlocal')
hiddenimports += collect_submodules('ujson')
hiddenimports += collect_submodules('urllib3')
hiddenimports += collect_submodules('wheel')
hiddenimports += collect_submodules('yaml')
hiddenimports += collect_submodules('yarl')


a = Analysis(
    ['/tmp/tap_postgres_entry.py'],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='tap-postgres',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='tap-postgres',
)
