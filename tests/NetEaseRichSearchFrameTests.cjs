'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const [candidate,runtime,output]=process.argv.slice(2),id='00000000-0000-4000-8000-000000000001';
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(runtime,'NetEase/dist/index.js'))).digest('hex'),'0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88');
const key=crypto.createHash('sha256').update(id).digest();
function encrypted(value){const iv=crypto.randomBytes(16),cipher=crypto.createCipheriv('aes-256-cbc',key,iv);return Buffer.from(JSON.stringify({iv:iv.toString('hex'),data:Buffer.concat([cipher.update(JSON.stringify(value)),cipher.final()]).toString('hex')})).toString('base64');}
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:2048,publicKeyEncoding:{type:'spki',format:'pem'},privateKeyEncoding:{type:'pkcs8',format:'pem'}});
const files={'.netease_mcp_device.json':Buffer.from(JSON.stringify({deviceId:id})).toString('base64'),'.config/ncm-cli/config.json':Buffer.from('{}').toString('base64'),
 '.config/ncm-cli/credentials.enc.json':encrypted({appId:'synthetic-application-only',privateKey:pair.privateKey}),
 '.config/ncm-cli/tokens.enc.json':encrypted({namedToken:'SYNTHETIC-NAMED-SESSION',namedRefreshToken:'SYNTHETIC-REFRESH',namedTokenExpireAt:Date.now()+3600000})};
pair.privateKey='';key.fill(0);
let credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files})).toString('base64');
const pages=[],sizes=[],ids=[];let offset=0;
for(let call=0;call<4;call++) {
 const request={schema:1,operation:'search',call_id:id,credential,network_allowed:true,arguments:{keyword:'Synthetic query',offset:String(offset)}};
 const child=cp.spawnSync(process.execPath,['--no-warnings','--experimental-loader',path.join(__dirname,'fixtures/NetEaseReadOutputMockLoader.mjs'),path.join(__dirname,'fixtures/NetEaseSharedReadBridgeChild.cjs'),candidate,path.join(runtime,'Bridge')],
 {input:JSON.stringify(request),env:{PATH:'/usr/bin:/bin',TMPDIR:'/tmp',LANG:'C',LC_ALL:'C',PYTHONDONTWRITEBYTECODE:'1',ARL_SYNTHETIC_SHARED_CASE:'rich_business_frame'},timeout:12000,maxBuffer:524288});request.credential='';
 assert.equal(child.error,undefined);assert.equal(child.status,0);assert.equal(child.signal,null);
 const rows=child.stdout.toString().trim().split('\n').map(line=>({bytes:Buffer.byteLength(line+'\n'),value:JSON.parse(line)}));child.stdout.fill(0);
 const completed=rows.filter(row=>row.value.event==='read_complete');assert.equal(completed.length,1);
 const frame=completed[0].value,read=frame.result;assert.ok(completed[0].bytes<=262144);assert.equal(typeof frame.credential,'string');
 credential=frame.credential;frame.credential='';assert.equal(read.state,'authorized_read');assert.equal(read.session,'present');
 const songs=read.payload.songs,page=read.payload.search_page;assert.equal(page.offset,offset);assert.ok(songs.length>0);
 for(const [i,song] of songs.entries()) {
  assert.equal(song.song_id,(offset+i+1).toString(16).padStart(32,'0'));const info=song.metadata.business_info;
  assert.equal(info.artists.length,20);assert.equal(info.artists[19].name,'a'.repeat(200));assert.equal(info.artists[19].id,(119).toString(16).padStart(32,'0'));
  assert.equal(info.album.id,'b'.repeat(32));assert.equal(info.duration_raw,240000);assert.equal(info.duration_unit,null);assert.equal(info.recording_edition,null);
  assert.equal(song.play_flag,true);assert.equal(song.private_cloud_song,false);ids.push(song.song_id);
 }
 pages.push(read);sizes.push(completed[0].bytes);
 if(page.next_offset===null)break;
 assert.equal(read.payload.complete,false);assert.equal(page.coverage,'budget_exhausted');assert.equal(page.next_offset,offset+songs.length);offset=page.next_offset;
}
credential='';assert.ok(pages.length>1);assert.equal(ids.length,20);assert.equal(new Set(ids).size,20);assert.equal(pages.at(-1).payload.search_page.next_offset,null);
// Only public synthetic read payloads are persisted. No credential envelope.
fs.writeFileSync(output,JSON.stringify({pages,private_frame_sizes:sizes}));
console.log(JSON.stringify({status:'PASS',official_pinned_cli:true,actual_private_credential_frame:true,pages:pages.map(p=>p.payload.songs.length),frame_bytes:sizes,all_20_song_fields_preserved:true,real_network:0,real_credentials:0}));
