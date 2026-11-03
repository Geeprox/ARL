"use strict";
const assert = require("node:assert/strict");
const {webcrypto, createHash} = require("node:crypto");
const {File} = require("node:buffer");
const {Delivery, MAX_WIDGET_BYTES} = require("../integrations/nas/download_widget.js");
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const fault = async (code, fn) => assert.rejects(fn, error => error.code === code);
function reply(value) {return {content:[{type:"text",text:JSON.stringify(value)}],structuredContent:value,isError:false};}
function fixture(raw = Buffer.from("ARL-Test-20261030 synthetic download\n")) {
  let now=0, uploads=0, calls=0, links=0;
  const persisted=[];
  const manifest={schema_version:1,operation:"download",operation_id:"227f742e-c203-4c2c-97aa-84518fa02f11",
    source_ref:"synthetic",config_generation:1,connection_epoch:"e".repeat(32),transfer_ref:"f".repeat(64),
    object_ref:"a".repeat(64),revision:"b".repeat(64),name:"ARL-Test-20261030-文件.bin",size:raw.length,
    sha256:hash(raw),expires_in_seconds:120,complete:true,direction:"download",downloadable_artifact:false,
    delivery_code:"platform_file_publisher_required"};
  const platform={
    async uploadFile(file, options){uploads++;assert.equal(file.name,manifest.name);assert.equal(file.size,raw.length);
      assert.deepEqual(options,{library:false});assert.equal(hash(Buffer.from(await file.arrayBuffer())),hash(raw));
      return {fileId:"file_actual_host_fixture"};},
    async getFileDownloadUrl({fileId}){links++;assert.equal(fileId,"file_actual_host_fixture");return {downloadUrl:"https://download.example.invalid/actual-host-reference?signature=synthetic"};}
  };
  const host={now:()=>now,crypto:webcrypto,File,platform,
    atob:text=>Buffer.from(text,"base64").toString("binary"),btoa:text=>Buffer.from(text,"binary").toString("base64"),
    persist:value=>persisted.push(JSON.parse(JSON.stringify(value))),
    async callTool(name,args){calls++;assert.equal(name,"mio_nas_transfer_read");
      assert.equal(args.connection_epoch,manifest.connection_epoch);assert.equal(args.operation_id,manifest.operation_id);
      const data=raw.subarray(args.offset,args.offset+args.length),end=args.offset+data.length;
      return reply({...args,schema_version:1,operation:"transfer_read",bytes_read:data.length,data_base64:data.toString("base64"),
        chunk_sha256:hash(data),eof:end===raw.length,next_offset:end===raw.length?null:end,
        downloadable_artifact:false,delivery_code:"platform_file_publisher_required"});}
  };
  return {manifest,host,platform,persisted,setNow:v=>now=v,stats:()=>({uploads,calls,links}),delivery:()=>new Delivery(manifest,host)};
}
async function run() {
  let checks=0;
  for(const size of [0,37,3*1024*1024+17]) {
    const f=fixture(Buffer.alloc(size,0x63)), d=f.delivery(), result=await d.publish();
    assert.equal(result.fileId,"file_actual_host_fixture");assert.equal(result.downloadable_artifact,true);
    assert.equal(result.platform_readback_verified,false);assert.equal(result.source_sha256,f.manifest.sha256);
    assert.equal(f.stats().uploads,1);assert.equal(f.stats().calls,Math.max(1,Math.ceil(size/32768)));
    assert.ok(f.persisted.some(v=>v.state==="uploading"&&v.fileId===null));
    await fault("delivery_already_consumed",()=>d.publish());checks++;
  }
  {
    const f=fixture();delete f.platform.uploadFile;await fault("platform_file_api_unavailable",()=>f.delivery().publish());
    assert.deepEqual(f.stats(),{uploads:0,calls:0,links:0});checks++;
  }
  {
    const f=fixture();f.manifest.size=MAX_WIDGET_BYTES+1;await fault("browser_memory_budget",()=>f.delivery().publish());
    assert.equal(f.stats().calls,0);checks++;
  }
  {
    const f=fixture(),d=f.delivery();f.setNow(120000);await fault("transfer_expired",()=>d.publish());
    assert.equal(f.stats().uploads,0);assert.equal(f.stats().calls,0);checks++;
  }
  for(const mutate of [
    page=>page.connection_epoch="0".repeat(32),page=>page.sha256="0".repeat(64),
    page=>page.chunk_sha256="0".repeat(64),page=>page.eof=false,
    page=>page.next_offset=37,page=>page.data_base64="!!!!",page=>page.bytes_read=0]) {
    const f=fixture(),call=f.host.callTool;f.host.callTool=async(...args)=>{const r=await call(...args);mutate(r.structuredContent);return reply(r.structuredContent);};
    await assert.rejects(()=>f.delivery().publish());assert.equal(f.stats().uploads,0);assert.equal(f.stats().calls,1);checks++;
  }
  {
    const f=fixture();f.manifest.sha256="0".repeat(64);
    await fault("whole_file_integrity_failed",()=>f.delivery().publish());assert.equal(f.stats().uploads,0);checks++;
  }
  {
    const f=fixture(),call=f.host.callTool;f.host.callTool=async(...args)=>{const value=await call(...args);value.structuredContent={};return value;};
    await fault("transfer_representations_differ",()=>f.delivery().publish());assert.equal(f.stats().uploads,0);checks++;
  }
  {
    const f=fixture();let attempted=0;f.platform.uploadFile=async()=>{attempted++;throw new Error("unknown upload effect");};
    const d=f.delivery();await assert.rejects(()=>d.publish());assert.equal(d.state,"upload_unknown");
    await fault("delivery_already_consumed",()=>d.publish());assert.equal(attempted,1);checks++;
  }
  {
    const f=fixture();f.platform.getFileDownloadUrl=async()=>{throw new Error("temporary host read failure");};
    const d=f.delivery();await assert.rejects(()=>d.publish());assert.equal(d.state,"uploaded");assert.equal(d.fileId,"file_actual_host_fixture");
    f.platform.getFileDownloadUrl=async()=>({downloadUrl:"https://download.example.invalid/returned-by-host"});
    const result=await d.refreshDownloadUrl();assert.equal(result.downloadable_artifact,true);assert.equal(f.stats().uploads,1);checks++;
  }
  {
    const f=fixture();f.platform.getFileDownloadUrl=async()=>({downloadUrl:"javascript:alert('no')"});
    await fault("platform_download_reference_invalid",()=>f.delivery().publish());checks++;
  }
  {
    const f=fixture();f.manifest.name="../unrelated";assert.throws(()=>f.delivery(),e=>e.code==="invalid_download_manifest");checks++;
  }
  process.stdout.write(JSON.stringify({checks,synthetic_host:true,real_platform_uploads:0,real_nas_calls:0})+"\n");
}
run().catch(error=>{process.stderr.write(error.stack+"\n");process.exitCode=1;});
