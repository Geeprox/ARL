'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls');
const {EventEmitter}=require('node:events');
const deny=()=>{throw new Error('synthetic_real_network_forbidden');};
net.connect=net.createConnection=tls.connect=deny;
net.Socket.prototype.connect=deny;
const routes=['/openapi/v1/ncm/cli/manifest','/openapi/music/basic/playlist/created/get/v2',
 '/openapi/music/basic/playlist/detail/get/v2','/openapi/music/basic/playlist/song/list/get/v3',
 '/openapi/music/basic/search/song/get/v2'];
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!routes.includes(u.pathname))deny();
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);
