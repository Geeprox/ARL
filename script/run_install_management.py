"""Reviewed transaction only; timeout waits for owned worker and lock completion.
Does not prepare a plan, expand authorization, or automatically start recovery.
"""
import argparse,json,sys
from pathlib import Path
from finalize_build import staged_release
ROOT=Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',required=True,type=Path);parser.add_argument('--action',required=True,choices=['apply','rollback']);parser.add_argument('--transaction',required=True);parser.add_argument('--plan-sha256');args=parser.parse_args()
    try:
        with staged_release(args.output) as app:
            sys.path.insert(0,str(app/'Contents/Resources/CoreRuntime/code'))
            from arl.install_transaction import Layout
            from arl.install_platform import MacPlatform
            platform=MacPlatform(Layout(Path.home()),app/'Contents/MacOS/ARL')
            code,result=platform.management(args.transaction,args.action,args.plan_sha256)
            print(json.dumps(result));return code
    except Exception as error:
        print(json.dumps({'status':'blocked','error':getattr(error,'code','install_operation_failed'),'automatic_recovery_started':False}));return 2
if __name__=='__main__':raise SystemExit(main())
