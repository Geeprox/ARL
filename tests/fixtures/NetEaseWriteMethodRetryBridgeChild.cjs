'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls');
const {EventEmitter}=require('node:events'),write=fs.writeSync.bind(fs);
const deny=()=>{throw Error('synthetic_real_network_forbidden');};
net.connect=net.createConnection=tls.connect=deny;net.Socket.prototype.connect=deny;
let calls=0;
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!['/openapi/v1/ncm/cli/manifest','/openapi/music/playlist/create','/openapi/music/playlist/song/add'].includes(u.pathname))deny();
 if(u.pathname!=='/openapi/v1/ncm/cli/manifest') {if(!['GET','POST'].includes(options.method)||++calls>1)deny();}
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
process.on('exit',()=>write(1,JSON.stringify({event:'synthetic_effect_observation',calls})+'\n'));
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);
