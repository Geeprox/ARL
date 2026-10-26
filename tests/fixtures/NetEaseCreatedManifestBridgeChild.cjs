'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls');
const {EventEmitter}=require('node:events');
const deny=()=>{throw new Error('synthetic_real_network_forbidden');};
net.connect=net.createConnection=tls.connect=deny;
net.Socket.prototype.connect=deny;
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!['/openapi/v1/ncm/cli/manifest','/openapi/music/basic/playlist/created/get/v2'].includes(u.pathname))deny();
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
const source=fs.readFileSync(process.argv[2],'utf8'),runtimeBridge=process.argv[3];
new Function('require','__dirname',source)(require,runtimeBridge);
