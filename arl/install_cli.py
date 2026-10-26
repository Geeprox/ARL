"""CLI invoked only by the signed ARL entry before constructing the GUI."""
import argparse
import json
import os
from pathlib import Path
import pwd
from .install_transaction import Layout,Transaction,InstallFault,load
from .install_platform import MacPlatform,prepare_payloads

def main(arguments,bundle,parent_pid=None):
    parser=argparse.ArgumentParser(prog='ARL manage')
    parser.add_argument('action',choices=['plan','apply','rollback','status'])
    parser.add_argument('--package',type=Path);parser.add_argument('--transaction');parser.add_argument('--plan-sha256')
    args=parser.parse_args(arguments)
    try:
        account=Path(pwd.getpwuid(os.geteuid()).pw_dir)
        layout=Layout(account);platform=MacPlatform(layout,Path(bundle)/'Contents/MacOS/ARL',management_parent=parent_pid);engine=Transaction(layout,platform)
        if args.action=='plan':
            if args.package is None:raise InstallFault('package_required')
            payloads,details=prepare_payloads(layout,platform,args.package)
            result=engine.prepare(payloads,details)
            result['blockers']=['legacy_app_drain_unsupported'] if any(not a.get('drain_supported') for a in details['old_apps']) else []
        else:
            if args.transaction is None:raise InstallFault('transaction_required')
            if args.action=='apply':
                if args.plan_sha256 is None:raise InstallFault('reviewed_plan_digest_required')
                result=engine.apply(args.transaction,args.plan_sha256)
            elif args.action=='rollback':result=engine.rollback(args.transaction)
            else:
                _,_,journal=engine.read(args.transaction);result={k:journal[k] for k in ['id','phase','result','error']}
        print(json.dumps(result));return 0
    except Exception as error:
        print(json.dumps({'status':'blocked','error':error.code if isinstance(error,InstallFault) else 'install_operation_failed','credentials_or_business_data_modified':False}));return 2
