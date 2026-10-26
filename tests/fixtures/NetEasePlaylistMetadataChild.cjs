'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls'),{EventEmitter}=require('node:events'),write=fs.writeSync.bind(fs);
const deny=()=>{throw Error('SYNTHETIC_REAL_NETWORK_FORBIDDEN');};
net.connect=net.createConnection=tls.connect=deny;net.Socket.prototype.connect=deny;
const route='/openapi/music/basic/playlist/'+(process.env.ARL_METADATA_OP==='playlist_update_name'?'name':'desc')+'/update';
let calls=0;
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!['/openapi/v1/ncm/cli/manifest',route].includes(u.pathname))deny();
 if(u.pathname===route&&(++calls>1||options.method!=='POST'))deny();
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
process.on('exit',()=>write(1,JSON.stringify({event:'synthetic_effect_observation',calls})+'\n'));
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);
