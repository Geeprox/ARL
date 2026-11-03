/* NAS bytes -> verified File -> the actual optional ChatGPT file host APIs.
 * No fetch(), credential, URL builder, server upload endpoint or auto retry.
 * The vanilla MCP Apps bridge below follows the official OpenAI UI example.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.ARLNASDownload = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";
  const CHUNK = 32768, MAX_WIDGET_BYTES = 32 * 1024 * 1024;
  const COMMON = ["operation_id", "source_ref", "config_generation", "connection_epoch"];
  const BINDING = [...COMMON, "transfer_ref", "size", "sha256"];
  const BASE = [...BINDING, "schema_version", "operation", "downloadable_artifact", "delivery_code"];
  const MANIFEST = [...BASE, "name", "object_ref", "revision", "expires_in_seconds", "complete", "direction"];
  const PAGE = [...BASE, "offset", "length", "bytes_read", "data_base64", "chunk_sha256", "eof", "next_offset"];
  function fail(code) { const error = new Error(code); error.code = code; throw error; }
  function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
  function keys(value, expected) {
    return object(value) && Object.keys(value).sort().join("\0") === [...expected].sort().join("\0");
  }
  function integer(value, low, high) { return Number.isSafeInteger(value) && value >= low && value <= high; }
  function hex(value, count) { return typeof value === "string" && new RegExp(`^[0-9a-f]{${count}}$`).test(value); }
  function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (object(value)) return `{${Object.keys(value).sort().map(k => JSON.stringify(k) + ":" + canonical(value[k])).join(",")}}`;
    return JSON.stringify(value);
  }
  function valueOf(reply) {
    if (!object(reply) || typeof reply.isError !== "boolean" || !object(reply.structuredContent)
        || !Array.isArray(reply.content) || reply.content.length !== 1
        || reply.content[0]?.type !== "text" || typeof reply.content[0]?.text !== "string"
        || new TextEncoder().encode(reply.content[0].text).length > 196608) fail("invalid_transfer_reply");
    let value;
    try { value = JSON.parse(reply.content[0].text); } catch (_) { fail("invalid_transfer_reply"); }
    if (canonical(value) !== canonical(reply.structuredContent)) fail("transfer_representations_differ");
    if (reply.isError) {
      const code = value?.error?.code;
      fail(typeof code === "string" && /^[A-Za-z][A-Za-z0-9_]{0,95}$/.test(code) ? code : "transfer_failed");
    }
    return value;
  }
  function manifest(value) {
    if (!keys(value, MANIFEST) || value.schema_version !== 1 || value.operation !== "download"
        || typeof value.operation_id !== "string" || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.operation_id)
        || typeof value.source_ref !== "string" || !/^[A-Za-z0-9_-]{1,96}$/.test(value.source_ref)
        || !integer(value.config_generation, 1, Number.MAX_SAFE_INTEGER) || !hex(value.connection_epoch, 32)
        || !["object_ref", "revision", "transfer_ref", "sha256"].every(k => hex(value[k], 64))
        || !integer(value.size, 0, Number.MAX_SAFE_INTEGER)
        || typeof value.name !== "string" || new TextEncoder().encode(value.name).length > 255 || !value.name.length
        || [".", ".."].includes(value.name) || /[\/\\\u0000-\u001f\u007f-\u009f]/.test(value.name)
        || !Number.isFinite(value.expires_in_seconds) || value.expires_in_seconds <= 0 || value.expires_in_seconds > 120
        || value.complete !== true || value.direction !== "download" || value.downloadable_artifact !== false
        || value.delivery_code !== "platform_file_publisher_required") fail("invalid_download_manifest");
    return Object.freeze({...value});
  }
  async function sha256(bytes, crypto) {
    return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(x => x.toString(16).padStart(2, "0")).join("");
  }
  function decode(text, atob, btoa) {
    if (typeof text !== "string" || text.length > 4 * Math.ceil(CHUNK / 3)) fail("invalid_chunk");
    let binary;
    try { binary = atob(text); } catch (_) { fail("invalid_chunk"); }
    if (btoa(binary) !== text) fail("invalid_chunk");
    return Uint8Array.from(binary, c => c.charCodeAt(0));
  }
  class Delivery {
    constructor(value, host) {
      this.manifest = manifest(value);
      this.host = host;
      this.received = host.now();
      this.state = "ready_to_verify";
      this.fileId = null;
      this.downloadUrl = null;
      this.publishStarted = false;
    }
    live() {
      if (this.host.cancelled?.()) fail("cancelled");
      const elapsed = this.host.now() - this.received;
      if (!Number.isFinite(elapsed) || elapsed < 0 || elapsed >= this.manifest.expires_in_seconds * 1000) fail("transfer_expired");
    }
    async publish() {
      if (this.state !== "ready_to_verify") fail("delivery_already_consumed");
      if (typeof this.host.platform?.uploadFile !== "function" || typeof this.host.platform?.getFileDownloadUrl !== "function") fail("platform_file_api_unavailable");
      if (this.manifest.size > MAX_WIDGET_BYTES) fail("browser_memory_budget");
      if (typeof this.host.callTool !== "function" || !this.host.crypto?.subtle || typeof this.host.File !== "function") fail("host_capability_unavailable");
      this.state = "verifying";
      const bytes = new Uint8Array(this.manifest.size);
      let offset = 0;
      try {
        do {
          this.live();
          const args = Object.fromEntries(BINDING.map(key => [key, this.manifest[key]]));
          args.offset = offset;
          args.length = Math.min(CHUNK, Math.max(1, this.manifest.size - offset));
          const page = valueOf(await this.host.callTool("mio_nas_transfer_read", args));
          this.live();
          if (!keys(page, PAGE) || !BINDING.every(key => page[key] === this.manifest[key])
              || page.schema_version !== 1 || page.operation !== "transfer_read"
              || page.offset !== offset || page.length !== args.length
              || page.bytes_read !== Math.min(args.length, this.manifest.size-offset)
              || page.downloadable_artifact !== false || page.delivery_code !== "platform_file_publisher_required") fail("invalid_chunk");
          const raw = decode(page.data_base64, this.host.atob, this.host.btoa);
          if (raw.length !== page.bytes_read || await sha256(raw, this.host.crypto) !== page.chunk_sha256) fail("chunk_integrity_failed");
          const end = offset + raw.length, eof = end === this.manifest.size;
          if (page.eof !== eof || page.next_offset !== (eof ? null : end) || (!eof && raw.length === 0)) fail("invalid_chunk_sequence");
          bytes.set(raw, offset);
          offset = end;
          this.host.progress?.(offset, this.manifest.size);
          if (eof) break;
        } while (true);
        this.live();
        if (await sha256(bytes, this.host.crypto) !== this.manifest.sha256) fail("whole_file_integrity_failed");
        this.live();
        const file = new this.host.File([bytes], this.manifest.name, {type:"application/octet-stream"});
        this.state = "uploading";
        this.host.persist?.(this.receipt());
        this.publishStarted = true;
        // This is the real, feature-detected ChatGPT extension. No guessed URL
        // or API key is substituted when the current host does not expose it.
        const result = await this.host.platform.uploadFile(file, {library:false});
        if (!object(result) || typeof result.fileId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,511}$/.test(result.fileId)) fail("platform_file_reference_invalid");
        this.fileId = result.fileId;
        this.state = "uploaded";
        this.host.persist?.(this.receipt());
      } catch (error) {
        this.state = this.publishStarted ? "upload_unknown" : "failed";
        this.host.persist?.(this.receipt());
        throw error;
      }
      return this.refreshDownloadUrl();
    }
    receipt() {
      return {state:this.state, name:this.manifest.name, size:this.manifest.size,
        operation_id:this.manifest.operation_id, source_sha256:this.manifest.sha256, fileId:this.fileId,
        platform_readback_verified:false, automatic_upload_retry:false};
    }
    async refreshDownloadUrl() {
      if (!this.fileId || !["uploaded", "download_ready"].includes(this.state)) fail("platform_file_reference_required");
      const result = await this.host.platform.getFileDownloadUrl({fileId:this.fileId});
      let url;
      try { url = new URL(result?.downloadUrl); } catch (_) { fail("platform_download_reference_invalid"); }
      if (url.protocol !== "https:" || url.username || url.password) fail("platform_download_reference_invalid");
      this.downloadUrl = url.href;
      this.state = "download_ready";
      this.host.persist?.(this.receipt());
      return {...this.receipt(), downloadUrl:this.downloadUrl, downloadable_artifact:true};
    }
  }
  return {Delivery, manifest, MAX_WIDGET_BYTES};
});
