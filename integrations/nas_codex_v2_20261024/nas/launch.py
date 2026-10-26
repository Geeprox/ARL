"""Start fixed loopback adapter, then the image's original application command."""
import os,sys,subprocess,json,sqlite3
from pathlib import Path
app=os.environ['FRIDAY_LLM_APP']
secret=Path('/friday-secret/token').read_text().strip()
if app=='pdf2zh':
    os.environ.update(OPENAI_BASE_URL='http://127.0.0.1:19421/v1',OPENAI_API_KEY=secret,OPENAI_MODEL='arl/package/medium')
    os.chdir('/home/app')
    config=Path('/home/app/.config/PDFMathTranslate/config.json')
    value=json.loads(config.read_text()) if config.exists() else {}
    envs={'OPENAI_BASE_URL':'http://127.0.0.1:19421/v1','OPENAI_API_KEY':secret,'OPENAI_MODEL':'arl/package/medium'}
    found=False
    for row in value.get('translators',[]):
        if row.get('name')=='openai':
            if row.get('envs',{}).get('OPENAI_API_KEY') not in (None,'',secret):raise RuntimeError('existing_openai_credential_preserved')
            row['envs']=envs;found=True
    if not found:value.setdefault('translators',[]).append({'name':'openai','envs':envs})
    config.parent.mkdir(parents=True,exist_ok=True)
    backup=config.with_name('config.before-friday-arl.json')
    if config.exists() and not backup.exists():backup.write_bytes(config.read_bytes());backup.chmod(0o600)
    config.write_text(json.dumps(value));config.chmod(0o600)
elif app=='bilinote':
    import hashlib
    source=Path('/app/backend/app/gpt/provider/OpenAI_compatible_provider.py')
    patch=Path('/friday-adapter/BiliProvider.py')
    if hashlib.sha256(source.read_bytes()).hexdigest() not in {'0aa96c6dc83e6aa6ea77421f8cccbdaec5b8718a9a82d3a4df98449a24b1374b','fe8372f9734938c9e36795d44c6b13a2ca7ebb76a61203f7379d03ff17848f8c'} or hashlib.sha256(patch.read_bytes()).hexdigest()!='fe8372f9734938c9e36795d44c6b13a2ca7ebb76a61203f7379d03ff17848f8c':
        raise RuntimeError('bilinote_provider_source_drift')
    if hashlib.sha256(source.read_bytes()).hexdigest()=='0aa96c6dc83e6aa6ea77421f8cccbdaec5b8718a9a82d3a4df98449a24b1374b':
        source.with_suffix('.before-arl-v2.py').write_bytes(source.read_bytes())
        source.write_bytes(patch.read_bytes())
    database=Path('/app/backend/data/bili_note.db')
    with sqlite3.connect(database) as db:
        tables={row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {'providers','models'}<=tables:raise RuntimeError('bilinote_schema_not_initialized')
        identity='9a18d353-cac6-5764-a3cb-619037dcdf93'
        row=db.execute('SELECT api_key,base_url,type FROM providers WHERE id=?',(identity,)).fetchone()
        if row is not None and row!=(secret,'http://127.0.0.1:19421/v1','custom'):raise RuntimeError('provider_configuration_changed')
        backup=database.with_name('bili_note.before-friday-arl.sqlite')
        if not backup.exists():
            with sqlite3.connect(backup) as dest:db.backup(dest)
            backup.chmod(0o600)
        db.execute('INSERT OR IGNORE INTO providers (id,name,logo,type,api_key,base_url,enabled) VALUES (?,?,?,?,?,?,1)',(identity,'ARL Codex','','custom',secret,'http://127.0.0.1:19421/v1'))
        if not db.execute('SELECT id FROM models WHERE provider_id=? AND model_name=?',(identity,'arl/package/medium')).fetchone():db.execute('INSERT INTO models (provider_id,model_name) VALUES (?,?)',(identity,'arl/package/medium'))
if app=='bilinote':
    catalog_path=Path('/friday-queue/catalog.json')
    if catalog_path.exists():
        catalog=json.loads(catalog_path.read_text())
        with sqlite3.connect(database) as db:
            for row in catalog.get('models',[]):
                name=row['id']
                if not db.execute('SELECT id FROM models WHERE provider_id=? AND model_name=?',(identity,name)).fetchone():db.execute('INSERT INTO models (provider_id,model_name) VALUES (?,?)',(identity,name))
process=subprocess.Popen([sys.executable,'-I','-B','/friday-adapter/local_api.py',app],env=os.environ.copy())
os.execvp(sys.argv[1],sys.argv[1:])
