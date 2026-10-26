'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls'),{EventEmitter}=require('node:events');
const deny=()=>{throw Error('SYNTHETIC_REAL_NETWORK_FORBIDDEN');};
net.connect=net.createConnection=tls.connect=deny;net.Socket.prototype.connect=deny;
const specs=JSON.parse(fs.readFileSync(process.env.ARL_LIBRARY_SPECS,'utf8')),spec=specs[process.env.ARL_LIBRARY_OPERATION];
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!['/openapi/v1/ncm/cli/manifest',spec.method.path].includes(u.pathname))deny();
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);
