'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2],'utf8');
const cases=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const split=source.lastIndexOf('\ntry {');assert.ok(split>0);
let transportCalls=0;
const http={},https={request(){transportCalls++;return {setTimeout(){},on(){}};}};
const boundRequire=name=>name==='node:http'?http:name==='node:https'?https:require(name);
const {FiniteDiagnostics:D,installNetworkBoundary}=new Function('require','__dirname',source.slice(0,split)+'\nreturn {FiniteDiagnostics,installNetworkBoundary};')(boundRequire,path.dirname(process.argv[2]));
const checks=[],rows=[];
for(const c of cases){
 assert.equal(D.qrURLReason(c.url),c.reason,c.name);
 const d=new D('00000000-0000-4000-8000-000000000001',x=>rows.push(x),()=>true,()=>100);
 d.qrPayload({code:200,data:{qrCodeUrl:c.url,uniKey:'ARL-SYNTHETIC-KEY'}});
 assert.equal(rows.at(-1).kind,c.reason===null?'succeeded':'invalid_response',c.name);
 checks.push(c.name);
}
for(const [name,value,reason] of [['absent',undefined,'qr_missing_value'],['object',{},'qr_wrong_type'],['empty','','qr_empty_value'],['overlength','x'.repeat(4097),'qr_too_long']]){
 assert.equal(D.qrURLReason(value),reason,name);checks.push(name);
}
const encoded=JSON.stringify(rows);
for(const marker of ['163cn.tv','https:','ARL-SYNTHETIC','uniKey','qrCodeUrl'])assert.ok(!encoded.includes(marker));
checks.push('no_payload_or_hostname_in_diagnostics');
const originalFetch=global.fetch;
try{
 installNetworkBoundary(true);
 for(const host of ['163cn.tv','www.163cn.tv','p5.music.126.net','example.invalid'])
  assert.throws(()=>https.request('https://'+host+'/ARL-SYNTHETIC'));
 assert.equal(transportCalls,0);checks.push('qr_content_hosts_do_not_gain_network_access');
 https.request('https://openncm.music.163.com/ARL-SYNTHETIC');
 assert.equal(transportCalls,1);checks.push('only_existing_api_host_reaches_stub_transport');
}finally{global.fetch=originalFetch;}
process.stdout.write(JSON.stringify({status:'PASS',checks:checks.length,passed:checks,network_calls:0,real_credentials:0,official_CLI_executed:false})+'\n');
