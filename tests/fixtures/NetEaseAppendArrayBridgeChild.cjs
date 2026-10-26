'use strict';
const fs=require('node:fs'),https=require('node:https'),net=require('node:net'),tls=require('node:tls');
const {EventEmitter}=require('node:events'),write=fs.writeSync.bind(fs);
const deny=()=>{throw Error('synthetic_real_network_forbidden');};
net.connect=net.createConnection=tls.connect=deny;net.Socket.prototype.connect=deny;
let calls=0,tamper_count=0,wire=null;
const scenario=process.env.ARL_SYNTHETIC_ARRAY_CASE,stringify=JSON.stringify;
// Fault injection into the official CLI's generated business payload. The
// production bridge and official package remain byte-for-byte unmodified.
JSON.stringify=function(value,...rest) {
 if(scenario?.startsWith('append_query_')&&value&&Object.keys(value).sort().join()==='playlistId,songIdList'&&
   value.playlistId==='1'.repeat(32)&&Array.isArray(value.songIdList)&&value.songIdList.length===1) {
  if(++tamper_count>4)throw Error('excessive_fault_injection');
  value={...value,songIdList:scenario==='append_query_wrong_song'?['3'.repeat(32)]:['2'.repeat(32),'3'.repeat(32)]};
 }
 if(scenario?.startsWith('append_tamper_')&&value&&Object.keys(value).sort().join()==='playlistId,songIdList'&&
   value.playlistId==='1'.repeat(32)&&Array.isArray(value.songIdList)&&value.songIdList.length===1) {
  if(++tamper_count>4)throw Error('excessive_fault_injection');
  const song='2'.repeat(32);
  value={...value,songIdList:scenario==='append_tamper_extra'?[song,'3'.repeat(32)]:
    scenario==='append_tamper_wrong'?['3'.repeat(32)]:scenario==='append_tamper_scalar'?song:[2]};
 }
 return stringify.call(JSON,value,...rest);
};
https.request=(url,options)=>{
 const u=new URL(url);
 if(u.hostname!=='openncm.music.163.com'||!['/openapi/v1/ncm/cli/manifest','/openapi/music/playlist/create','/openapi/music/basic/playlist/song/batch/like'].includes(u.pathname))deny();
 if(u.pathname!=='/openapi/v1/ncm/cli/manifest') {if(!['GET','POST'].includes(options.method)||++calls>1)deny();}
 if(u.pathname==='/openapi/music/basic/playlist/song/batch/like'&&options.method==='POST') {
  const signed=JSON.parse(options.body),biz=JSON.parse(signed.bizContent);
  wire={post:true,url_query_empty:u.search==='',song_list_array:Array.isArray(biz.songIdList),count:biz.songIdList.length,
   only_selected_song:Array.isArray(biz.songIdList)&&biz.songIdList.length===1&&biz.songIdList[0]==='2'.repeat(32),
   playlist_unchanged:biz.playlistId==='1'.repeat(32),has_signature:typeof signed.sign==='string'&&signed.sign.length>0};
 }
 const r=new EventEmitter();r.setTimeout=()=>r;r.end=()=>{};r.destroy=()=>{};return r;
};
process.on('exit',()=>write(1,JSON.stringify({event:'synthetic_effect_observation',calls,tamper_count,wire})+'\n'));
new Function('require','__dirname',fs.readFileSync(process.argv[2],'utf8'))(require,process.argv[3]);
