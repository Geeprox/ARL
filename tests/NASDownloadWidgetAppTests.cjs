"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm");
const {webcrypto,createHash}=require("node:crypto"),{File}=require("node:buffer");
const hash=x=>createHash("sha256").update(x).digest("hex");
const core=fs.readFileSync("integrations/nas/download_widget.js","utf8");
const html=fs.readFileSync("integrations/nas/download_widget.html","utf8").replace("/* ARL_NAS_DOWNLOAD_CORE */",()=>core);
const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]);
const raw=Buffer.from("ARL-Test-20261030 component acceptance\n");
const manifest={schema_version:1,operation:"download",operation_id:"69b37792-5067-43eb-9e63-b7d19bbf0c77",
 source_ref:"synthetic",config_generation:1,connection_epoch:"e".repeat(32),transfer_ref:"f".repeat(64),
 object_ref:"a".repeat(64),revision:"b".repeat(64),name:"ARL-Test-20261030-<img>.txt",size:raw.length,
 sha256:hash(raw),expires_in_seconds:120,complete:true,direction:"download",downloadable_artifact:false,
 delivery_code:"platform_file_publisher_required"};
async function app({files=true,restore=null}={}){
 const elements=new Map(),listeners=[],sent=[];let uploads=0,reads=0,ready=false;
 for(const id of ["name","detail","status","progress","prepare","refresh","download"])
  elements.set(id,{textContent:"",hidden:["refresh","download","progress"].includes(id),disabled:id==="prepare"});
 const notify=message=>{for(const listener of listeners)listener({source:parent,data:message});};
 const parent={postMessage(message){sent.push(message);queueMicrotask(()=>{
  if(message.method==="ui/initialize"){
   assert.equal(message.params.protocolVersion,"2026-01-26");
   notify({jsonrpc:"2.0",id:message.id,result:{}});
  }else if(message.method==="ui/notifications/initialized"){
   ready=true;notify({jsonrpc:"2.0",method:"ui/notifications/tool-result",params:{structuredContent:manifest}});
  }else if(message.method==="tools/call"){
   reads++;assert.equal(message.params.name,"mio_nas_transfer_read");const args=message.params.arguments;
   const chunk=raw.subarray(args.offset,args.offset+args.length),end=args.offset+chunk.length;
   const value={...args,schema_version:1,operation:"transfer_read",bytes_read:chunk.length,data_base64:chunk.toString("base64"),
    chunk_sha256:hash(chunk),eof:end===raw.length,next_offset:end===raw.length?null:end,
    downloadable_artifact:false,delivery_code:"platform_file_publisher_required"};
   notify({jsonrpc:"2.0",id:message.id,result:{content:[{type:"text",text:JSON.stringify(value)}],structuredContent:value,isError:false}});
  }
 });}};
 const openai={widgetState:restore,setWidgetState(value){this.widgetState=value;}};
 if(files){
  openai.uploadFile=async (file,options)=>{uploads++;assert.equal(options.library,false);assert.deepEqual(Object.keys(options),["library"]);assert.equal(hash(Buffer.from(await file.arrayBuffer())),hash(raw));return {fileId:"file_actual_component_host"};};
  openai.getFileDownloadUrl=async ({fileId})=>{assert.equal(fileId,"file_actual_component_host");return {downloadUrl:"https://download.example.invalid/host-actual"};};
 }
 const window={parent,openai,addEventListener(name,listener){if(name==="message")listeners.push(listener);}};
 const context=vm.createContext({window,document:{getElementById:id=>elements.get(id)},performance:{now:()=>0},
  crypto:webcrypto,File,URL,TextEncoder,Uint8Array,setTimeout,clearTimeout,
  atob:x=>Buffer.from(x,"base64").toString("binary"),btoa:x=>Buffer.from(x,"binary").toString("base64")});
 for(const script of scripts)new vm.Script(script,{filename:"nas-download-widget.html"}).runInContext(context);
 for(let tries=0;tries<30&&!ready;tries++)await new Promise(resolve=>setImmediate(resolve));
 assert.ok(ready,"MCP Apps initialized handshake required");
 return {elements,openai,stats:()=>({uploads,reads}),sent};
}
async function run(){
 {
  const a=await app();assert.equal(a.elements.get("name").textContent,manifest.name);assert.equal(a.stats().uploads,0);
  assert.equal(a.elements.get("name").innerHTML,undefined);
  await a.elements.get("prepare").onclick();assert.equal(a.stats().uploads,1);assert.equal(a.stats().reads,1);
  assert.equal(a.elements.get("download").hidden,false);assert.equal(a.elements.get("download").href,"https://download.example.invalid/host-actual");
  assert.equal(a.openai.widgetState.privateContent.nasDelivery.fileId,"file_actual_component_host");
  await a.elements.get("refresh").onclick();assert.equal(a.stats().uploads,1);
 }
 {
  const a=await app({files:false});await a.elements.get("prepare").onclick();
  assert.equal(a.stats().uploads,0);assert.equal(a.stats().reads,0);assert.match(a.elements.get("status").textContent,/未提供文件下载接口/);
 }
 {
  const previous={operation_id:manifest.operation_id,source_sha256:manifest.sha256,name:manifest.name,size:manifest.size,state:"upload_unknown",fileId:null};
  const a=await app({restore:{privateContent:{nasDelivery:previous}}});assert.equal(a.elements.get("prepare").disabled,true);
  assert.match(a.elements.get("status").textContent,/避免重复上传/);assert.doesNotMatch(a.elements.get("status").textContent,/文件库/);assert.equal(a.stats().uploads,0);
 }
 {
  const previous={operation_id:manifest.operation_id,source_sha256:manifest.sha256,name:manifest.name,size:manifest.size,state:"uploaded",fileId:"file_actual_component_host"};
  const a=await app({restore:{privateContent:{nasDelivery:previous}}});assert.equal(a.elements.get("prepare").disabled,true);
  await a.elements.get("refresh").onclick();assert.equal(a.elements.get("download").hidden,false);
  assert.equal(a.stats().uploads,0);assert.equal(a.stats().reads,0);
 }
 process.stdout.write(JSON.stringify({checks:4,mcp_apps_handshake:true,real_platform_uploads:0,real_nas_calls:0})+"\n");
}
run().catch(error=>{process.stderr.write(error.stack+"\n");process.exitCode=1;});
