'use strict';
// Private pipe protocol for the signed native credential owner. Official CLI
// bytes remain unchanged. No caller-supplied executable, command or HOME path.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const {Writable} = require('node:stream');
const {syncBuiltinESMExports} = Module;
const rawRead = fs.readSync.bind(fs);
const rawWrite = fs.writeSync.bind(fs);
const actualRead = fs.readFileSync.bind(fs);
const HOME = '/ARL-Virtual-Home';
const MAX = 131072;
// Raw official JSON can exceed 64 KiB while the allowlisted projection is small.
// Keep login/write capture unchanged; read output remains bounded and private.
const MAX_READ_CLI_OUTPUT = 1048576;
// Local work budget for the pinned CLI representation, separate from HTTP.
// JSON numeric formatting can grow even compact output (1e20 becomes 21 digits).
// Do not apply the HTTP byte limit again to normalized CLI text. This existing
// 35,651,617-byte formatting/work ceiling is local policy, not a provider limit.
const MAX_READ_CLI_FORMATTED = MAX_READ_CLI_OUTPUT + (MAX_READ_CLI_OUTPUT+1)*(1+2*16);
const persistent = new Set(['.netease_mcp_device.json','.config/ncm-cli/config.json',
  '.config/ncm-cli/credentials.enc.json','.config/ncm-cli/tokens.enc.json']);
const CLI_SHA = '0d586c070cbe90a60132056a42ae8fd565b73294353faf4842cd10f9e634bb88';
const operationArgs = {prepare:['--help'], status:['login','--check','--output','json'], login:['login','--output','json']};
let finished = false;
let publicResult = null;
let readContext = null;
let diagnostic = null;

// Complete business evidence travels only through the private owned pipe to an owner-only local journal.
// It is deliberately separate from the small public unified-log diagnostics.
let businessAudit = null;
// Preserve the received bytes. JSON text keeps whitespace and numeric tokens;
// non-UTF8 bodies use reversible base64 rather than replacement characters.
function businessBody(bytes) {
  const text=bytes.toString('utf8');
  return Buffer.from(text,'utf8').equals(bytes)?{body_text:text,body_encoding:'utf8'}:
    {body_base64:bytes.toString('base64'),body_encoding:'base64'};
}
function businessEvidence(event,record) {
  // Authentication exchange payloads are outside the business-log scope.
  if(record.path===REFRESH_PATH)return null;
  const recordID=crypto.randomUUID();
  if(businessAudit) {
    const value={event,span_id:businessAudit.spanID,operation:readContext?.operation??null,
      stage:readContext?.stage??'discovery',at_utc:new Date().toISOString(),...record};
    const bytes=Buffer.from(JSON.stringify(value)),digest=crypto.createHash('sha256').update(bytes).digest('hex');
    const parts=Math.max(1,Math.ceil(bytes.length/65536));
    for(let part=0;part<parts;part++)frame({schema:1,call_id:businessAudit.callID,event:'business_record',
      record_id:recordID,part,parts,sha256:digest,payload:bytes.subarray(part*65536,(part+1)*65536).toString('base64')});
  }
  return recordID;
}
function providerExchange(record,recordID,body=null) {
  // Raw records stay in the protected local journal, never in MCP/tool output.
  const code=value=>Number.isSafeInteger(value)?value:typeof value==='string'&&/^[A-Za-z0-9_.:-]{1,64}$/.test(value)?value:null;
  const fields={path:record.path,method:record.method,http_status:record.http_status??null,
    elapsed_ms:record.elapsed_ms??null,received_bytes:record.received_bytes??null,
    code:code(body?.code),sub_code:code(body?.subCode),
    body_reference:recordID?{record_id:recordID,storage:businessAudit?'local_business_log':'not_retained',
      bytes:record.received_bytes??null,complete:!!businessAudit}:null};
  // Known read-only library errors may include the provider's business hint.
  // Keep auth exchanges excluded and known secret/credential URLs out of public output.
  if(libraryOperations.has(readContext?.operation)&&typeof body?.message==='string'&&
     Buffer.byteLength(body.message)<=2048&&secretFreeProjection(body.message)&&!providerAuthenticationURL(body.message))
    fields.provider_message=body.message;
  // Token validation diagnostics contain only fixed rule names, types and
  // booleans. Never forward the authentication body or any upload token/key.
  if(record.cover_token_validation) {
    fields.failure_stage='provider';fields.failure_code='invalid_cover_token_reply';
    fields.cover_token_validation=record.cover_token_validation;
  }
  return {fields,omitted_authentication_fields:[]};
}

// This observed tuple is an empty page only in an already validated playlist.
// null data and other endpoints remain provider failures. A contradictory total
// still becomes drift in the collector, never false complete coverage.
function trackEmptyObservation(raw,business) {
  const offset=Number(business?.offset);
  if(readContext?.stage!=='tracks'||!readContext.validatedPlaylist||raw?.code!==200||String(raw?.subCode)!=='10007'||
     !Array.isArray(raw.data)||raw.data.length!==0||!Number.isSafeInteger(offset)||offset<0)return null;
  if(offset===0&&readContext.validatedPlaylistTrackCount!==0)
    return Number.isSafeInteger(readContext.validatedPlaylistTrackCount)?'empty_page_count_conflict':null;
  return 'terminal_empty';
}
// BEGIN FINITE_DIAGNOSTICS: pure projection, exercised directly by fixtures.
class FiniteDiagnostics {
  constructor(callID, emit, safe = () => true, clock = () => performance.now(), refresh = () => {}) {
    this.callID=callID;this.emit=emit;this.safe=safe;this.clock=clock;this.started=clock();this.refresh=refresh;
    this.count=0;this.last='';this.phase='initialize';this.failed=false;this.failure=null;this.lastValues=null;
  }
  static phases=new Set(['owner','initialize','qr_create','qr_payload','qr_delivery','qr_display','qr_poll','account_read','effect','readback','token_store','bridge','provider','complete']);
  static kinds=new Set(['started','succeeded','waiting','confirming','ignored','expired','provider_rejected','network_unavailable','network_timeout','signing_failed','invalid_response','runtime_exited','storage_failed','cancelled','unconfirmed','cleanup_unproven','endpoint_rejected','login_required']);
  static endpoints=new Set(['official_api','official_qr_create','official_qr_poll','public_ip_lookup','package_update','other']);
  static reasons=new Set(['endpoint_scheme','endpoint_host','endpoint_port','endpoint_credentials','endpoint_socket','endpoint_tls','network_disabled',
    'qr_missing_value','qr_wrong_type','qr_empty_value','qr_too_long','qr_url_invalid','qr_url_scheme','qr_url_host','qr_url_credentials','qr_url_port',
    'qr_frame_invalid','qr_frame_write','qr_not_delivered','qr_render','stale_callback','login_unconfirmed']);
  // Only effect errors: redact the complete field before truncating UTF-8.
  // Preserve unfamiliar safe reasons and message/msg provenance, never data.
  providerText(value,limit) {
    if(typeof value!=='string')return undefined;
    if(Buffer.byteLength(value)>65536)return '[redacted:oversize]';
    let text=value;
    for(let i=0;i<2;i++){try {const decoded=decodeURIComponent(text);if(decoded===text)break;text=decoded;}catch{break;}}
    text=text.replace(/\\u([0-9a-f]{4})/gi,(_match,hex)=>String.fromCharCode(parseInt(hex,16)))
      .replace(/\\x([0-9a-f]{2})/gi,(_match,hex)=>String.fromCharCode(parseInt(hex,16)))
      .replace(/[\p{Cf}\p{Cs}]/gu,'').replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/g,'');
    const privateValues=[...privatePatterns,...Object.values(readContext?.arguments||{}).filter(v=>typeof v==='string')];
    const forms=new Set();
    for(const value of privateValues)if(value) {
      const encoded=Buffer.from(value).toString('base64');
      for(const form of [value,encoded,encoded.replace(/=+$/,'').replace(/\+/g,'-').replace(/\//g,'_'),encodeURIComponent(value),JSON.stringify(value).slice(1,-1)])if(form)forms.add(form);
    }
    for(const secret of [...forms].sort((a,b)=>b.length-a.length))text=text.split(secret).join('[redacted]');
    text=text
      .replace(/-----BEGIN [^-]+-----[\s\S]*?(?:-----END [^-]+-----|$)/g,'[redacted]')
      .replace(/\b(?:Authorization|Proxy-Authorization|Cookie|Set-Cookie|X-[A-Za-z0-9-]+)\s*:\s*[^\r\n]*/gi,'[redacted]')
      .replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_=.-]+/gi,'[redacted]')
      .replace(/\b(?:[a-z][a-z0-9+.-]*:\/\/|www\.)[^\s<>"']+/gi,'[redacted]')
      .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi,'[redacted]')
      .replace(/\b(?:access[_-]?token|refresh[_-]?token|namedToken|token|private[_-]?key|api[_-]?key|client[_-]?secret|signature|sign|cookie|authorization|account|username|nickname|phone|email|uid|(?:user|account|device|app|session|request|trace|original)[_-]?id)\s*[:=]\s*[^,;\r\n]*/gi,'[redacted]')
      .replace(/\b[0-9a-f]{12,}\b/gi,'[redacted]')
      .replace(/\b\d{5,}\b/g,'[redacted]')
      .replace(/\b(?=[A-Za-z0-9+/_=-]{24,}(?:\b|$))(?=[A-Za-z0-9+/_=-]*[a-z])(?=[A-Za-z0-9+/_=-]*[A-Z])(?=[A-Za-z0-9+/_=-]*[0-9])[A-Za-z0-9+/_=-]{24,}/g,'[redacted]')
      .replace(/(?:%[0-9a-f]{2}){3,}/gi,'[redacted]')
      .replace(/[\p{Cc}\p{Cf}\p{Cs}]/gu,' ')
      .replace(/\s+/gu,' ').trim();
    // Catch anything exposed by decoding/normalizing, including request values.
    if(!this.safe(text))return undefined;
    if(!text)return '[redacted]';
    if(Buffer.byteLength(text)<=limit)return text;
    let result='',bytes=0;
    for(const scalar of text){const count=Buffer.byteLength(scalar);if(bytes+count>limit-3)break;result+=scalar;bytes+=count;}
    result=result.trimEnd()+'…';
    return this.safe(result)?result:undefined;
  }
  static endpointFor(url) {
    if(url.hostname==='openncm.music.163.com') {
      const phase=this.phaseFor(url.pathname);
      return phase==='qr_create'?'official_qr_create':phase==='qr_poll'?'official_qr_poll':'official_api';
    }
    if(['api.ipify.org','api.ip.sb','ifconfig.me'].includes(url.hostname))return 'public_ip_lookup';
    if(['registry.npmjs.org','rnpm.hz.netease.com'].includes(url.hostname))return 'package_update';
    return 'other';
  }
  static qrURLReason(value) {
    if(value===undefined||value===null)return 'qr_missing_value';
    if(typeof value!=='string')return 'qr_wrong_type';
    if(value.length===0)return 'qr_empty_value';
    if(value.length>4096)return 'qr_too_long';
    let url;try {url=new URL(value);}catch{return 'qr_url_invalid';}
    if(url.protocol!=='https:')return 'qr_url_scheme';
    // Official QR payload short link; never fetched by this bridge. See docs/NETEASE-QR-URL-POLICY.md.
    if(!(url.hostname==='163cn.tv'||url.hostname==='music.163.com'||url.hostname.endsWith('.music.163.com')))return 'qr_url_host';
    if(url.username||url.password)return 'qr_url_credentials';
    if(url.port&&url.port!=='443')return 'qr_url_port';
    return null;
  }
  qrPayload(response) {
    const reason=FiniteDiagnostics.qrURLReason(response?.data?.qrCodeUrl);
    this.record('qr_payload',reason?'invalid_response':'succeeded',reason?{reason_code:reason}:{});
  }
  static phaseFor(pathname) {
    if(pathname.startsWith('/openapi/music/basic/user/oauth2/qrcode'))return 'qr_create';
    if(pathname==='/openapi/music/basic/oauth2/device/login/qrcode/get')return 'qr_poll';
    if(['/openapi/music/basic/user/profile/get/v2','/openapi/music/basic/playlist/created/get/v2'].includes(pathname))return 'account_read';
    return 'provider';
  }
  number(value, min=-999999, max=999999) {
    if(typeof value==='string'&&!this.safe(value))return null;
    if(typeof value==='string'&&/^-?[0-9]{1,6}$/.test(value))value=Number(value);
    return Number.isSafeInteger(value)&&value>=min&&value<=max&&this.safe(String(value))?value:null;
  }
  record(phase,kind,fields={}) {
    if(!FiniteDiagnostics.phases.has(phase)||!FiniteDiagnostics.kinds.has(kind)||this.count>=128)return;
    this.phase=phase;
    const values={phase,kind,http_status:this.number(fields.http_status,100,599),code:this.number(fields.code),
      sub_code:this.number(fields.sub_code),provider_status:this.number(fields.provider_status,0,9999)};
    if(FiniteDiagnostics.endpoints.has(fields.endpoint_class))values.endpoint_class=fields.endpoint_class;
    if(FiniteDiagnostics.reasons.has(fields.reason_code))values.reason_code=fields.reason_code;
    if(phase==='effect'&&kind==='provider_rejected') {
      for(const [key,limit] of [['provider_code',64],['provider_message',512],['provider_msg',512]]) {
        const value=this.providerText(fields[key],limit);if(value!==undefined)values[key]=value;
      }
    }
    if(phase==='provider'&&kind==='ignored'&&fields.cloud_catalog&&this.safe(fields.cloud_catalog))values.cloud_catalog=fields.cloud_catalog;
    if(phase==='provider'&&kind==='ignored'&&fields.cloud_metadata&&this.safe(fields.cloud_metadata))values.cloud_metadata=fields.cloud_metadata;
    const stable=JSON.stringify(values);if(stable===this.last)return;this.last=stable;
    this.lastValues=values;
    if(!['started','succeeded','waiting','confirming','ignored'].includes(kind)){this.failed=true;this.failure=values;}
    else if(phase==='qr_payload'&&kind==='succeeded'&&this.failure?.phase==='provider'&&this.failure?.kind==='endpoint_rejected') {
      this.failed=false;this.failure=null; // Valid payload, not HTTP200, supersedes the earlier nonterminal refusal.
    }
    this.emit({schema:1,call_id:this.callID,event:'diagnostic',sequence:++this.count,...values,
      elapsed_ms:Math.max(0,Math.min(360000,Math.round(this.clock()-this.started)))});
  }
  error(error,phase=this.phase,httpStatus=undefined) {
    const message=typeof error?.message==='string'?error.message:'';
    const kind=message.includes('RSA SHA256 签名失败:')?'signing_failed':
      ['provider_endpoint_rejected','insecure_transport_rejected','network_not_authorized'].includes(error?.code)?'endpoint_rejected':
      error?.code==='provider_timeout'||error?.name==='AbortError'||error?.type==='aborted'?'network_timeout':
      ['duplicate_json_key','invalid_json','json_depth_limit','provider_response_limit'].includes(error?.code)||error?.type==='max-size'?'invalid_response':'network_unavailable';
    const prior=kind==='endpoint_rejected'&&this.lastValues?.kind==='endpoint_rejected'?this.lastValues:{};
    this.record(phase,kind,{http_status:httpStatus,endpoint_class:prior.endpoint_class,reason_code:prior.reason_code});
  }
  response(phase,status,value) {
    this.refresh(value);
    const fields={http_status:status,code:value?.code,sub_code:value?.subCode,
      provider_status:phase==='qr_poll'?value?.data?.status:undefined};
    let kind=value===null||typeof value!=='object'||Array.isArray(value)||fields.code===undefined?'invalid_response':
      status<200||status>=300||value?.success===false||![0,200,'0','200'].includes(fields.code)?'provider_rejected':'succeeded';
    if(phase!=='qr_poll'&&kind==='succeeded'&&fields.sub_code!==undefined&&fields.sub_code!==null&&![0,200,'0','200'].includes(fields.sub_code))kind='unconfirmed';
    if(phase==='qr_poll'&&kind==='succeeded') {
      if(fields.provider_status===800)kind='expired';
      else if(fields.provider_status===801)kind='waiting';
      else if(fields.provider_status===802)kind='confirming';
      else if(fields.provider_status!==803)kind='invalid_response';
    }
    if(phase==='effect'&&kind==='provider_rejected') {
      fields.provider_code=value?.code;
      fields.provider_message=value?.message;
      fields.provider_msg=value?.msg;
    }
    this.record(phase,kind,fields);
  }
}
// END FINITE_DIAGNOSTICS
const LIBRARY_READ_SPECS = {"search_all":{"group":"search","method":"all","path":"/openapi/music/basic/complex/search","httpMethod":"GET","fields":["keyword"],"required":["keyword"],"types":{"keyword":"string"},"library":true},"search_album":{"group":"search","method":"album","path":"/openapi/music/basic/search/album/get/v2","httpMethod":"GET","fields":["keyword","limit","offset"],"required":["keyword"],"types":{"keyword":"string","limit":"number","offset":"number"},"library":true},"search_playlist":{"group":"search","method":"playlist","path":"/openapi/music/basic/search/playlist/get/v2","httpMethod":"GET","fields":["keyword","limit","offset"],"required":["keyword"],"types":{"keyword":"string","limit":"number","offset":"number"},"library":true},"album_get":{"group":"album","method":"get","path":"/openapi/music/basic/album/detail/get/v2","httpMethod":"POST","fields":["albumId","descFlag"],"required":["albumId"],"types":{"albumId":"string","descFlag":"boolean"},"library":true},"album_tracks":{"group":"album","method":"tracks","path":"/openapi/music/basic/album/song/list/get/v2","httpMethod":"POST","fields":["albumId","qualityFlag"],"required":["albumId"],"types":{"albumId":"string","qualityFlag":"boolean"},"library":true},"album_collected":{"group":"album","method":"collected","path":"/openapi/music/basic/album/subed/get/v2","httpMethod":"GET","fields":["limit","offset"],"required":["limit","offset"],"types":{"limit":"number","offset":"number"},"library":true},"artist_songs":{"group":"artist","method":"songs","path":"/openapi/music/basic/song/artist/bypubtime/get/v2","httpMethod":"GET","fields":["artistId","limit","offset","startTime","endTime"],"required":["artistId","limit","offset","startTime","endTime"],"types":{"artistId":"string","limit":"number","offset":"number","startTime":"number","endTime":"number"},"library":true},"song_lyric":{"group":"song","method":"lyric","path":"/openapi/music/basic/song/lyric/get/v2","httpMethod":"GET","fields":["songId"],"required":["songId"],"types":{"songId":"string"},"library":true},"playlist_collected":{"group":"playlist","method":"collected","path":"/openapi/music/basic/playlist/subed/get/v2","httpMethod":"GET","fields":["limit","offset"],"required":[],"types":{"limit":"number","offset":"number"},"library":true},"playlist_get_tags":{"group":"playlist","method":"getTags","path":"/openapi/music/basic/playlist/tag/get/v2","httpMethod":"GET","fields":[],"required":[],"types":{},"library":true}};
const libraryOperations = new Set(Object.keys(LIBRARY_READ_SPECS));
const readOperations = new Set(['search','cloud_songs','user_playlists','playlist_detail',...libraryOperations]);
const metadataOperations = new Set(['playlist_update_name','playlist_update_desc']);
const batchOperations = new Set(['playlist_update_tags','playlist_add_songs','playlist_reorder','playlist_remove_songs']);
const writeOperations = new Set(['playlist_create','playlist_append','playlist_cover',...metadataOperations,...batchOperations]);
const batchValues=(operation,args)=>({playlistId:args.playlist_id,[operation==='playlist_update_tags'?'tags':operation==='playlist_reorder'?'trackIds':'songIdList']:operation==='playlist_update_tags'?args.tags:args.song_ids});
const metadataValues=(operation,args)=>({playlistId:args.playlist_id,[operation==='playlist_update_name'?'name':'desc']:args.value});
const REFRESH_PATH = '/openapi/music/basic/user/oauth2/token/refresh/v2';
const COVER_TOKEN_PATH = '/openapi/whale/nos/upload/token/docid';
const COVER_PATH = '/openapi/music/basic/playlist/cover/update';
const MANIFEST_PATH = '/openapi/v1/ncm/cli/manifest';
const CREATED_PATH = '/openapi/music/basic/playlist/created/get/v2';
const DETAIL_PATH = '/openapi/music/basic/playlist/detail/get/v2';
const TRACKS_PATH = '/openapi/music/basic/playlist/song/list/get/v3';
// These command names and query fields are used by the pinned CLI's own
// CommandRunnerSource. Search's URL is provider-discovered, never guessed here.
const READ_SPECS = {
  ...LIBRARY_READ_SPECS,
  playlist_cover: {group:'playlist',method:'updateCover',path:COVER_PATH,fields:['playlistId','picIds'],effect:true},
  playlist_create: {group:'playlist',method:'create',fields:['playlistName'],effect:true},
  playlist_update_name: {group:'playlist',method:'updateName',path:'/openapi/music/basic/playlist/name/update',httpMethod:'POST',fields:['playlistId','name'],effect:true},
  playlist_update_desc: {group:'playlist',method:'updateDesc',path:'/openapi/music/basic/playlist/desc/update',httpMethod:'POST',fields:['playlistId','desc'],effect:true},
  playlist_update_tags: {group:'playlist',method:'updateTags',path:'/openapi/music/basic/playlist/tags/update',httpMethod:'POST',fields:['playlistId','tags'],effect:true},
  playlist_add_songs: {group:'playlist',method:'add',path:'/openapi/music/basic/playlist/song/batch/like',httpMethod:'POST',fields:['playlistId','songIdList'],effect:true},
  playlist_reorder: {group:'playlist',method:'reorder',path:'/openapi/music/basic/playlist/track/order/update',httpMethod:'POST',fields:['playlistId','trackIds'],effect:true},
  playlist_remove_songs: {group:'playlist',method:'remove',path:'/openapi/music/basic/playlist/song/batch/delete',httpMethod:'POST',fields:['playlistId','songIdList'],effect:true},
  playlist_append: {group:'playlist',method:'add',path:'/openapi/music/basic/playlist/song/batch/like',fields:['playlistId','songIdList'],effect:true},
  search: {group:'search',method:'song',fields:['keyword','limit','offset','trialScene']},
  cloud_songs: {group:'cloud',method:'list',path:'/openapi/music/cloud/song/list/cursor/get',fields:['cursor','limit']},
  user_playlists: {group:'playlist',method:'created',path:CREATED_PATH,fields:['limit','offset']},
  playlist_detail: {group:'playlist',path:DETAIL_PATH,fields:['playlistId']},
  tracks: {group:'playlist',method:'tracks',path:TRACKS_PATH,fields:['playlistId','limit','offset','trialScene','qualityFlag']}
};
const readFailure = (state,detail=null) => {
  if(readContext&&!readContext.failure) {readContext.failure=state;readContext.failureDetail=detail;readContext.failureProviderResult=readContext.lastProviderResult??null;}
};
// Finite error data only; never provider text, keyword, target IDs or payload.
function publicReadFailure(state,callID) {
  const defaults={contract_rejected:['runtime_output_missing','runtime'],provider_rejected:['provider_rejected','provider_response'],
    provider_unavailable:['provider_unavailable','provider_response'],login_required:['login_required','session'],refresh_rejected:['refresh_rejected','session']};
  const reasons=new Set(['runtime_output_missing','provider_rejected','provider_unavailable','login_required','refresh_rejected',
    'provider_resource_missing','manifest_contract_rejected','cli_output_missing','cli_output_too_large','cli_output_invalid','result_schema_invalid','provider_response_invalid','session_state_invalid','response_too_large']);
  const stages=new Set(['runtime','provider_response','session','manifest','cli_output','projection']);
  const fallback=defaults[state]||defaults.contract_rejected,detail=readContext?.failureDetail;
  const reason=reasons.has(detail?.reason)?detail.reason:fallback[0],stage=stages.has(detail?.stage)?detail.stage:fallback[1];
  const nextStep=state==='provider_unavailable'?'retry_read_manually':['login_required','refresh_rejected'].includes(state)?'check_login_in_arl':
    state==='provider_rejected'?'inspect_provider_response':'inspect_adapter';
  const result={reason,stage,retryable:state==='provider_unavailable',automatic_retry:false,correlation_id:callID,next_step:nextStep,
    output_bytes:['cli_output_too_large','response_too_large'].includes(reason)&&Number.isSafeInteger(detail?.outputBytes)?detail.outputBytes:null,
    output_limit_bytes:reason==='response_too_large'?MAX*2:reason==='cli_output_too_large'?([MAX_READ_CLI_OUTPUT,MAX_READ_CLI_FORMATTED].includes(detail?.outputLimit)?detail.outputLimit:MAX_READ_CLI_OUTPUT):null,
    http_status:Number.isInteger(detail?.httpStatus)&&detail.httpStatus>=100&&detail.httpStatus<=599?detail.httpStatus:null,
    local_code:Object.values(READ_CONTRACT_CODES).includes(detail?.localCode)?detail.localCode:null};
  if(!readContext?.isWrite&&detail?.providerStatus)result.provider_status=detail.providerStatus;
  if(readContext?.failureProviderResult)result.provider_result=readContext.failureProviderResult;
  return result;
}

let exitCode = 0;
const files = new Map();
const directories = new Set(['','.', '.config','.config/ncm-cli']);
// BEGIN READ_CONTRACT_DIAGNOSTICS: fixed local rule numbers only, never values.
const READ_CONTRACT_CODES=Object.freeze({"read_cli_output_limit":-97062,"invalid_write_parameter_name":-97057,"unsupported_required_write_parameter":-97058,"invalid_write_parameter_type":-97059,"invalid_write_parameter_location":-97060,"missing_write_parameter":-97061,"invalid_write_http_method":-97051,"invalid_write_parameter_shape":-97052,"invalid_write_name":-97053,"invalid_write_auth":-97054,"invalid_write_route":-97055,"invalid_write_projected_fields":-97056,"invalid_json":-97001,"duplicate_json_key":-97002,"json_depth_limit":-97003,"invalid_manifest":-97004,"invalid_manifest_root":-97005,"ambiguous_read_group":-97006,"missing_read_group":-97007,"ambiguous_read_method":-97008,"unreviewed_method_field":-97009,"invalid_read_method":-97010,"invalid_read_parameter":-97011,"invalid_search_pagination_type":-97012,"missing_read_parameter":-97013,"manifest_contract_rejected":-97014,"missing_dynamic_manifest":-97015,"missing_fixed_operation_mapping":-97016,"read_endpoint_rejected":-97017,"unexpected_fetch_options":-97018,"unexpected_fetch_headers":-97019,"invalid_manifest_request":-97020,"invalid_signed_request":-97021,"invalid_manifest_business":-97022,"invalid_refresh_business":-97023,"invalid_read_http_method":-97024,"duplicate_signed_query":-97025,"read_business_mismatch":-97026,"missing_typed_output":-97027,"duplicate_cli_output":-97028,"invalid_read_reply":-97029,"ambiguous_result_array":-97030,"result_count_limit":-97031,"invalid_result_item":-97032,"invalid_encrypted_id":-97033,"invalid_original_id":-97034,"invalid_result_text":-97035,"invalid_track_count":-97036,"invalid_result_total":-97037,"invalid_has_more":-97038,"duplicate_result_id":-97039,"inconsistent_result_total":-97040,"inconsistent_pagination":-97041,"invalid_song_artists":-97042,"invalid_visible":-97043,"private_state_limit":-97044,"private_pattern_limit":-97045,"invalid_state_file":-97046,"invalid_encrypted_state":-97047,"discovery_limit":-97048,"consume_limit":-97049,"refresh_limit":-97050});
function recordReadContractFault(code) {
  if(!readContext||!diagnostic||!Object.hasOwn(READ_CONTRACT_CODES,code))return;
  // Preserve existing failure attribution and de-duplication. Only the normal
  // diagnostic sequence/count advances. No admission/result state changes.
  const previous={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try { diagnostic.record('bridge','ignored',{code:READ_CONTRACT_CODES[code]}); }
  catch {} // A diagnostic transport failure cannot replace the original guard error.
  finally { Object.assign(diagnostic,previous); }
}
// END READ_CONTRACT_DIAGNOSTICS
const fault = code => { recordReadContractFault(code);return Object.assign(new Error(code),{code}); };
const check = (ok, code) => { if (!ok) throw fault(code); };
// The unchanged private frame also contains the bounded credential envelope.
// Keep complete playlist items that fit this actual envelope, and expose the
// remainder through the same read offset. No pipe/credential/write bound changes.
function fitPlaylistReadFrame(data) {
  const size = value => Buffer.byteLength(JSON.stringify(value)+'\n');
  // Preserve every business field; only whole songs may move to a next page.
  if(data.operation==='search'&&data.result?.state==='authorized_read') {
    // Native JSON serialization may escape slashes and adds a fixed owner envelope.
    const fits=value=>size(value)<=MAX*2 && Buffer.byteLength(JSON.stringify(value.result).replace(/\//g,'\\/'))<=MAX*2-2048;
    if(fits(data))return data;
    const payload=data.result.payload,rows=payload?.songs,page=payload?.search_page;
    check(Array.isArray(rows)&&rows.length>0&&page&&Number.isSafeInteger(page.offset),'response_limit');
    const candidate=count=>{
      const next=page.offset+count,canContinue=page.continuation_supported===true;
      return {...data,result:{...data.result,payload:{...payload,songs:rows.slice(0,count),complete:false,
        search_page:{...page,next_offset:canContinue?next:null,coverage:canContinue?'budget_exhausted':'local_limit'}}}};
    };
    let low=1,high=rows.length,best=0;
    while(low<=high){const count=Math.floor((low+high)/2);if(fits(candidate(count))){best=count;low=count+1;}else high=count-1;}
    check(best>0,'response_limit');return candidate(best);
  }
  if(libraryOperations.has(data.operation)&&size(data)>MAX*2) {
    // The existing private frame carries both the result and the refreshed
    // credential. Report this measured frame boundary; never trim business JSON.
    readFailure('contract_rejected',{reason:'response_too_large',stage:'runtime',
      outputBytes:size(data),outputLimit:MAX*2,httpStatus:readContext.activeHTTPStatus});
    return {...data,result:{state:'contract_rejected',session:data.result.session,payload:null,
      failure:publicReadFailure('contract_rejected',data.call_id)}};
  }
  if(size(data)<=MAX*2)return data;
  check(data.event==='read_complete'&&data.result?.state==='authorized_read'&&
    ['user_playlists','playlist_detail'].includes(data.operation),'response_limit');
  const payload=data.result.payload,key=data.operation==='user_playlists'?'playlists':'songs',rows=payload?.[key],page=payload?.pagination;
  check(Array.isArray(rows)&&rows.length>1&&page&&
    ['stable_observed','budget_exhausted','continuation_end'].includes(page.state)&&
    Number.isSafeInteger(page.offset)&&page.offset>=0,'response_limit');
  const candidate = count => ({...data,result:{...data.result,payload:{...payload,[key]:rows.slice(0,count),complete:false,
    pagination:{...page,state:'budget_exhausted',items:count,next_offset:page.offset+count}}}});
  let low=1,high=rows.length-1,best=0;
  while(low<=high){const count=Math.floor((low+high)/2);
    if(Number.isSafeInteger(page.offset+count)&&size(candidate(count))<=MAX*2){best=count;low=count+1;}else high=count-1;
  }
  check(best>0,'response_limit');
  return candidate(best);
}
const frame = data => {
  const outgoing=data.event==='read_complete'?fitPlaylistReadFrame(data):data;
  const bytes = Buffer.from(JSON.stringify(outgoing)+'\n');
  check(bytes.length <= MAX*2, 'response_limit');
  let offset = 0;
  // Node may put fd1 in nonblocking mode. Keep a partial frame intact while
  // the native owner drains its pipe; never spin or wait without a deadline.
  const deadline = performance.now()+2000, pause = new Int32Array(new SharedArrayBuffer(4));
  while (offset < bytes.length) {
    check(performance.now()<deadline,'output_write_timeout');
    try {
      const count=rawWrite(1,bytes,offset,bytes.length-offset);
      check(Number.isInteger(count)&&count>0&&count<=bytes.length-offset,'invalid_output_write');
      offset+=count;
    } catch(error) {
      if(!['EAGAIN','EWOULDBLOCK','EINTR'].includes(error?.code))throw error;
      Atomics.wait(pause,0,0,5);
    }
  }
};

// JSON.parse alone silently accepts duplicate keys and replacement UTF-8.
function strictJSON(bytes) {
  const text = new TextDecoder('utf-8',{fatal:true}).decode(bytes);
  let index=0;
  const spaces=()=>{while(index<text.length && /[\t\n\r ]/.test(text[index]))index++;};
  const quoted=()=>{
    spaces();check(text[index]==='"','invalid_json');const start=index++;
    let escaped=false;
    while(index<text.length){const char=text[index++];if(escaped){escaped=false;continue;}
      if(char==='\\'){escaped=true;continue;}if(char==='"')return JSON.parse(text.slice(start,index));}
    throw fault('invalid_json');
  };
  const value=depth=>{
    check(depth<16,'json_depth_limit');spaces();check(index<text.length,'invalid_json');
    if(text[index]==='"'){quoted();return;}
    if(text[index]==='{'){
      index++;spaces();const keys=new Set();if(text[index]==='}'){index++;return;}
      while(true){const key=quoted();check(!keys.has(key),'duplicate_json_key');keys.add(key);
        spaces();check(text[index++]===':','invalid_json');value(depth+1);spaces();
        const next=text[index++];if(next==='}')return;check(next===',','invalid_json');}
    }
    if(text[index]==='['){
      index++;spaces();if(text[index]===']'){index++;return;}
      while(true){value(depth+1);spaces();const next=text[index++];if(next===']')return;check(next===',','invalid_json');}
    }
    const start=index;while(index<text.length&&!/[\t\n\r ,\]}]/.test(text[index]))index++;
    check(index>start,'invalid_json');
  };
  value(0);spaces();check(index===text.length,'invalid_json');return JSON.parse(text);
}
const object = value => value!==null && typeof value==='object' && !Array.isArray(value);
const keys = (value,expected) => object(value) && Object.keys(value).length===expected.length && expected.every(key=>Object.hasOwn(value,key));
const uuid = value => typeof value==='string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
function validateFile(name, bytes) {
  check(bytes.length>0 && bytes.length<=65536,'invalid_state_file');
  const value=strictJSON(bytes);check(object(value),'invalid_state_file');
  if(name.endsWith('.enc.json')) {
    check(keys(value,['iv','data']) && typeof value.iv==='string' && /^[a-f0-9]{32}$/i.test(value.iv) &&
      typeof value.data==='string' && value.data.length>0 && value.data.length%32===0 && /^[a-f0-9]+$/i.test(value.data),'invalid_encrypted_state');
  } else if(name.endsWith('config.json')) {
    check(!['deviceId','appId','privateKey','accessToken','refreshToken'].some(key=>Object.hasOwn(value,key)),'plaintext_state_rejected');
  } else check(uuid(value.deviceId),'invalid_device_state');
}

function readRequest() {
  const pieces = []; let total = 0;
  while (true) {
    const piece = Buffer.alloc(4096); const count = rawRead(0,piece,0,piece.length,null);
    if (!count) break;
    total += count; check(total <= MAX*2, 'input_limit'); pieces.push(piece.subarray(0,count));
  }
  const bytes = Buffer.concat(pieces);
  try { return strictJSON(bytes); }
  finally { bytes.fill(0); for (const p of pieces) p.fill(0); }
}
function virtualName(value) {
  if (value instanceof URL) value = require('node:url').fileURLToPath(value);
  if (Buffer.isBuffer(value)) value = value.toString('utf8');
  if (typeof value !== 'string') return null;
  const resolved = path.resolve(value);
  if (resolved === HOME) return '';
  return resolved.startsWith(HOME+'/') ? resolved.slice(HOME.length+1) : null;
}
// Only private owned material populates this set. Patterns never leave this
// process; both the original and rotated named sessions remain protected.
const privatePatterns=new Set();
let privatePatternBytes=0;
function rememberSecret(value) {
  if(typeof value!=='string'||value.length===0)return;
  check(Buffer.byteLength(value)<=MAX*2,'private_pattern_limit');
  for(const item of [value,Buffer.from(value).toString('base64'),encodeURIComponent(value)])if(!privatePatterns.has(item)) {
    privatePatternBytes+=Buffer.byteLength(item);check(privatePatternBytes<=4194304,'private_pattern_limit');privatePatterns.add(item);
  }
  check(privatePatterns.size<=256,'private_pattern_limit');
}
function rememberPrivateState() {
  const device=files.get('.netease_mcp_device.json');if(!device)return;
  const id=strictJSON(device).deviceId,key=crypto.createHash('sha256').update(id).digest();
  try {
    for(const name of persistent) {
      const bytes=files.get(name);if(!bytes)continue;
      rememberSecret(bytes.toString('utf8'));rememberSecret(bytes.toString('base64'));
      let plain;
      try {
        let value=strictJSON(bytes);
        if(name.endsWith('.enc.json')) {
          const decipher=crypto.createDecipheriv('aes-256-cbc',key,Buffer.from(value.iv,'hex'));
          plain=Buffer.concat([decipher.update(Buffer.from(value.data,'hex')),decipher.final()]);value=strictJSON(plain);
        }
        for(const field of ['deviceId','appId','privateKey','accessToken','refreshToken','namedToken','namedRefreshToken']) {
          if(typeof value[field]==='string') {
            rememberSecret(value[field]);
            if(field==='privateKey')for(const line of value[field].split(/\r?\n/))if(line.length>=16)rememberSecret(line);
          }
        }
      } finally {plain?.fill(0);}
    }
  } finally {key.fill(0);}
}
function secretFreeProjection(value) {
  if(typeof value==='string') {
    const forms=[value];try{forms.push(decodeURIComponent(value));}catch{}
    return !forms.some(text=>[...privatePatterns].some(secret=>text.includes(secret)));
  }
  if(Array.isArray(value))return value.every(secretFreeProjection);
  if(object(value))return Object.entries(value).every(([k,v])=>secretFreeProjection(k)&&secretFreeProjection(v));
  return true;
}
function refreshDiagnosticSecrets(response) {
  rememberPrivateState();
  // The pinned CLI's QR poll nests tokens in data.accessToken; refresh returns
  // them directly in data. Protect these strings before projecting any codes,
  // including before the CLI has saved its new session into the memory home.
  for(const value of [response?.data,response?.data?.accessToken]) {
    if(!object(value))continue;
    for(const field of ['accessToken','refreshToken'])rememberSecret(value[field]);
  }
}
function store(name, bytes) {
  check(name !== null && name.length <= 512, 'write_outside_private_home');
  // Logs have no persistent or diagnostic consumer, even inside the virtual home.
  if (/\.log(?:\..*)?$/.test(name)) return;
  const value = Buffer.isBuffer(bytes) ? Buffer.from(bytes) : Buffer.from(String(bytes));
  check(value.length <= MAX && files.size < 128, 'private_state_limit');
  if (readContext && name.endsWith('/manifest.json')) {
    try { readContext.manifests = validateManifests(strictJSON(value)); }
    catch(error) { readFailure('contract_rejected',{reason:'manifest_contract_rejected',stage:'manifest',localCode:READ_CONTRACT_CODES[error?.code],httpStatus:readContext.manifestHTTPStatus}); throw fault('manifest_contract_rejected'); }
  }
  const total = [...files].filter(([key]) => key !== name).reduce((n,[,b])=>n+b.length,0)+value.length;
  check(total <= MAX, 'private_state_limit');
  files.get(name)?.fill(0); files.set(name,value);
  if((readContext||diagnostic)&&persistent.has(name))rememberPrivateState();
  if(name==='.config/ncm-cli/tokens.enc.json')diagnostic?.record('token_store','succeeded');
}
function installMemoryHome() {
  process.env.HOME = HOME; process.env.XDG_CONFIG_HOME = HOME+'/.config';
  const originals = Object.fromEntries(['existsSync','readFileSync','statSync','lstatSync','accessSync','readdirSync'].map(k=>[k,fs[k].bind(fs)]));
  fs.existsSync = value => { const name=virtualName(value); return name===null ? originals.existsSync(value) : files.has(name)||directories.has(name); };
  fs.readFileSync = (value, options) => {
    const name=virtualName(value); if (name===null) return originals.readFileSync(value,options);
    check(files.has(name),'ENOENT'); const bytes=Buffer.from(files.get(name));
    const encoding=typeof options==='string' ? options : options?.encoding;
    return encoding ? bytes.toString(encoding) : bytes;
  };
  fs.writeFileSync = (value, bytes) => store(virtualName(value),bytes);
  fs.appendFileSync = (value, bytes) => { const name=virtualName(value); check(name!==null,'write_outside_private_home'); store(name,Buffer.concat([files.get(name)||Buffer.alloc(0),Buffer.from(bytes)])); };
  fs.mkdirSync = (value) => {
    const name=virtualName(value); check(name!==null,'write_outside_private_home');
    let current=''; for (const part of name.split('/')) { current=current ? current+'/'+part : part; directories.add(current); }
  };
  fs.chmodSync = value => check(virtualName(value)!==null,'write_outside_private_home');
  fs.renameSync = (from,to) => {
    const a=virtualName(from),b=virtualName(to); check(a!==null&&b!==null&&files.has(a),'invalid_private_rename');
    store(b,files.get(a)); files.get(a)?.fill(0); files.delete(a);
  };
  fs.unlinkSync = value => { const name=virtualName(value); check(name!==null,'write_outside_private_home'); files.get(name)?.fill(0); files.delete(name); };
  const remove = (value, options) => {
    const name=virtualName(value); check(name!==null,'write_outside_private_home');
    for (const key of [...files.keys()]) if (key===name || options?.recursive && key.startsWith(name+'/')) { files.get(key)?.fill(0); files.delete(key); }
    directories.delete(name);
  };
  fs.rmSync=remove; fs.rmdirSync=remove;
  for (const method of ['statSync','lstatSync']) fs[method] = (value,...rest) => {
    const name=virtualName(value); if (name===null) return originals[method](value,...rest);
    check(files.has(name)||directories.has(name),'ENOENT');
    return {isFile:()=>files.has(name),isDirectory:()=>directories.has(name),isSymbolicLink:()=>false,
      size:files.get(name)?.length||0,mode:files.has(name)?0o100600:0o40700,mtime:new Date(0),mtimeMs:0};
  };
  fs.accessSync = (value,...rest) => { const name=virtualName(value); if(name===null)return originals.accessSync(value,...rest); check(files.has(name)||directories.has(name),'ENOENT'); };
  fs.readdirSync = (value,options) => {
    const name=virtualName(value); if(name===null)return originals.readdirSync(value,options);
    check(directories.has(name),'ENOENT');
    const prefix=name?name+'/':'';return [...new Set([...files.keys(),...directories].filter(k=>k.startsWith(prefix)&&k!==name).map(k=>k.slice(prefix.length).split('/')[0]))];
  };
  fs.createWriteStream = value => {
    const name=virtualName(value); check(name!==null&&/\.log(?:\..*)?$/.test(name),'stream_write_not_admitted');
    const sink=new Writable({write(_chunk,_encoding,done){done();}});
    queueMicrotask(()=>sink.emit('open',-1)); return sink;
  };
  for (const method of ['readFile','writeFile','appendFile','mkdir','chmod','rename','unlink','rm','rmdir','stat','lstat','access','readdir']) {
    const sync=fs[method+'Sync']; if (!sync) continue;
    fs[method]=(...args)=>{const done=args.pop();try{done(null,sync(...args));}catch(e){done(e);}};
    fs.promises[method]=async(...args)=>sync(...args);
  }
  syncBuiltinESMExports();
}
function validateCoverBusiness(endpoint,business) {
  const cover=readContext.cover,a=readContext.arguments;
  if(endpoint===COVER_TOKEN_PATH) {
    check(keys(business,['fileName','fileSize','timeout','bizKey','resType'])&&
      business.fileName===path.basename(a.image_path)&&
      business.fileSize===cover.image.length&&business.timeout===3600&&business.bizKey==='a13c592a'&&business.resType===1,'invalid_cover_token_business');
    return;
  }
  check(endpoint===COVER_PATH&&cover.resourceID&&cover.uploadComplete&&keys(business,['playlistId','picIds'])&&
    business.playlistId===a.playlist_id,'invalid_cover_update_business');
  // Exact serialization is asserted by the pinned-CLI fixture. The SDK's
  // imgs_file_upload preprocessor supplies the resource id, never a caller path.
  check(typeof business.picIds==='string','invalid_cover_resource_binding');
  const pictures=strictJSON(Buffer.from(business.picIds));
  check(Array.isArray(pictures)&&pictures.length===1&&keys(pictures[0],['originId','format','width','height'])&&
    String(pictures[0].originId)===cover.resourceID&&pictures[0].format==='jpg'&&
    ['width','height'].every(k=>Number.isSafeInteger(pictures[0][k])&&pictures[0][k]>0),'invalid_cover_resource_binding');
}
// The provider's NOS object key is opaque. The pinned SDK URI-encodes the
// complete key, and coverNOSFetch binds that exact path to the fixed HTTPS host.
function validCoverNOSKey(value) {
  if(typeof value!=='string'||value.length<1||value.length>512||
    /[\u0000-\u001f\u007f]/.test(value)||value==='.'||value==='..')return false;
  try { encodeURIComponent(value);return true; } catch { return false; }
}
// Fixed metadata only; no key or token contents leave this boundary.
function coverTokenValidation(value) {
  const data=value?.data,resource=object(data)?data.resource:undefined;
  const kind=value=>value===undefined?'missing':value===null?'null':Array.isArray(value)?'array':typeof value;
  const rules=[['data_object',object(data)],
    ['token_string_length',object(data)&&typeof data.token==='string'&&data.token.length>0&&data.token.length<=16384],
    ['resource_object',object(resource)],
    ['doc_id_decimal',object(resource)&&/^[1-9][0-9]{0,19}$/.test(String(resource.docId))],
    ['bucket_yyimgs',object(resource)&&resource.bucket==='yyimgs'],
    ['nos_key_component',object(resource)&&validCoverNOSKey(resource.nosKey)]];
  const scalar=value=>Number.isSafeInteger(value)?value:typeof value==='string'&&/^-?[0-9]{1,20}$/.test(value)?value:null;
  return {schema:1,valid:rules.every(([,ok])=>ok),
    failed_rules:rules.filter(([,ok])=>!ok).map(([name])=>name),
    types:{data:kind(data),token_type:kind(data?.token),resource:kind(resource),
      doc_id:kind(resource?.docId),bucket:kind(resource?.bucket),nos_key:kind(resource?.nosKey)},
    provider_code:scalar(value?.code),provider_sub_code:scalar(value?.subCode),
    boundary:'token_reply_before_nos',token_accepted:false,cover_update_dispatched:false};
}
function acceptCoverToken(parsed,bytes,ok) {
  if(!ok||![0,200].includes(parsed?.code)||parsed?.success===false)return;
  const value=JSON.parse(bytes.toString('utf8'),(_key,v,c)=>typeof v==='number'&&Number.isInteger(v)&&!Number.isSafeInteger(v)?c.source:v);
  const data=value?.data,resource=data?.resource,cover=readContext.cover;
  const validation=coverTokenValidation(value);
  if(!validation.valid) {
    const error=fault('invalid_cover_token_reply');error.coverTokenValidation=validation;
    throw error;
  }
  rememberSecret(data.token);cover.token=data.token;cover.resourceID=String(resource.docId);cover.nosKey=resource.nosKey;
  // imgs_file_upload uses Hi, whose uploader runs even with fast=true.
  cover.uploadComplete=false;
}
async function coverNOSFetch(url,options,fetchURL) {
  const target=new URL(url),cover=readContext.cover;
  // SDK 0.1.7 first tries HTTP LBS; reject before IO. Its own documented
  // HTTPS fallback selects wanproxy-web. No fake discovery reply or SDK rewrite.
  check(target.protocol==='https:'&&target.hostname==='wanproxy-web.127.net'&&!target.port&&!target.username&&!target.password&&
    target.pathname==='/yyimgs/'+encodeURIComponent(cover.nosKey)&&!target.hash&&
    options.method==='POST'&&Object.keys(options).every(k=>['method','headers','body','signal'].includes(k)),'invalid_cover_upload_endpoint');
  check(object(options.headers)&&keys(options.headers,['x-nos-token'])&&options.headers['x-nos-token']===cover.token&&
    Buffer.isBuffer(options.body),'invalid_cover_upload_headers');
  const query=Object.fromEntries(target.searchParams);
  check([...target.searchParams].length===Object.keys(query).length&&
    keys(query,cover.context?['offset','complete','version','context']:['offset','complete','version'])&&
    query.version==='1.0'&&query.offset===String(cover.offset)&&
    (cover.context?query.context===cover.context:true),'invalid_cover_upload_query');
  const end=cover.offset+options.body.length;
  check(options.body.length>0&&end<=cover.image.length&&options.body.equals(cover.image.subarray(cover.offset,end))&&
    query.complete===String(end===cover.image.length)&&++cover.chunkAttempts<=3,'invalid_cover_upload_body');
  cover.dispatchURL=target.href;
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),10000);
  const abort=()=>controller.abort();options.signal?.addEventListener('abort',abort,{once:true});
  if(options.signal?.aborted)controller.abort();
  try {
    const module=await import(fetchURL);
    const response=await module.default(url,{...options,redirect:'error',size:1048576,signal:controller.signal});
    const bytes=Buffer.from(await response.arrayBuffer());
    let parsed;try{parsed=strictJSON(bytes);}finally{bytes.fill(0);}
    // SDK only consumes offset/context. The context authorizes a resumable
    // upload, so retain the business offset but omit that authentication field.
    const safe=providerRecord(parsed);if(object(safe.fields)&&Object.hasOwn(safe.fields,'context')) {
      delete safe.fields.context;safe.omitted_authentication_fields=[...new Set([...safe.omitted_authentication_fields,'authentication_context'])].sort();
    }
    cover.receipts.push(safe);
    businessEvidence('upload_response',{path:target.pathname,method:'POST',http_status:response.status,
      offset:cover.offset,bytes:options.body.length,provider_response:safe});
    if(response.ok) {
      check(object(parsed)&&parsed.offset===end&&(typeof parsed.context==='string'||end===cover.image.length),'invalid_cover_upload_reply');
      cover.offset=end;cover.context=parsed.context;cover.chunkAttempts=0;cover.uploadComplete=end===cover.image.length;
    }
    return {ok:response.ok,status:response.status,statusText:'',json:async()=>parsed,text:async()=>''};
  } finally {cover.dispatchURL=null;clearTimeout(timer);options.signal?.removeEventListener('abort',abort);}
}
function coverResult(state) {
  const cover=readContext.cover;
  const response=cover.response??null,complete=!!response,receipts=cover.receipts;
  const result={state,resource_id:cover.resourceID??null,provider_response:response,provider_response_complete:complete,
    provider_exchange:readContext.lastProviderResult??null,upload_receipts:receipts};
  check(secretFreeProjection(result),'private_cover_projection');return result;
}
function installNetworkBoundary(allowed) {
  const http=require('node:http'),https=require('node:https');
  http.request=()=>{
    diagnostic?.record('provider','endpoint_rejected',{endpoint_class:'other',reason_code:'endpoint_scheme'});
    throw fault('insecure_transport_rejected');
  };http.get=http.request;
  const original=https.request.bind(https);
  https.request=(...args)=>{
    const input=args[0];
    const options=typeof input==='string'||input instanceof URL ? (object(args[1])?args[1]:{}) : input;
    const url=typeof input==='string'||input instanceof URL ? new URL(input) :
      new URL((options.protocol||'https:')+'//'+(options.hostname||options.host)+(options.port?':'+options.port:'')+(options.path||'/'));
    const nos=readContext?.cover?.dispatchURL===url.href&&url.hostname==='wanproxy-web.127.net';
    const endpointAllowed=url.protocol==='https:' && (url.hostname==='openncm.music.163.com'||nos) &&
      (!url.port||url.port==='443') && !url.username && !url.password && !options.socketPath &&
      !options.auth && options.rejectUnauthorized!==false;
    if(!endpointAllowed) {
      const reason=url.protocol!=='https:'?'endpoint_scheme':url.hostname!=='openncm.music.163.com'?'endpoint_host':
        url.port&&url.port!=='443'?'endpoint_port':url.username||url.password||options.auth?'endpoint_credentials':
        options.socketPath?'endpoint_socket':'endpoint_tls';
      diagnostic?.record('provider','endpoint_rejected',{endpoint_class:FiniteDiagnostics.endpointFor(url),reason_code:reason});
    }
    check(endpointAllowed,'provider_endpoint_rejected');
    if(readContext&&!nos) {
      const method=String(options.method||'GET').toUpperCase();
      const discovery=url.pathname===MANIFEST_PATH && method==='POST';
      const refresh=url.pathname===REFRESH_PATH && method==='GET';
      const consume=readContext.activePath===url.pathname && method===(readContext.activeMethod||'GET');
      // Only the validated fixed command is admitted. Telemetry, updates,
      // anonymous login, additional writes and unrelated endpoints fail before IO.
      const token=!!readContext.cover&&url.pathname===COVER_TOKEN_PATH&&method==='POST'&&++readContext.cover.tokenCount===1;
      check(discovery||refresh||consume||token,'read_endpoint_rejected');
      if(refresh) { readContext.refreshAttempted=true; check(++readContext.refreshCount<=1,'refresh_limit'); }
      if(consume) {
        ++readContext.consumeCount;
        check(readContext.isWrite?readContext.consumeCount===1:performance.now()<readContext.pageDeadline,'consume_limit');
        if(readContext.isWrite)readContext.effectAttempted=true;
      }
      if(discovery) check(++readContext.discoveryCount<=1,'discovery_limit');
    }
    if(!allowed) {
      diagnostic?.record('provider','endpoint_rejected',{endpoint_class:FiniteDiagnostics.endpointFor(url),reason_code:'network_disabled'});
      readFailure('provider_unavailable');throw fault('network_not_authorized');
    }
    let request;
    try { request=original(...args); } catch { readFailure('provider_unavailable'); throw fault('provider_unavailable'); }
    request.setTimeout(10000,()=>{readFailure('provider_unavailable');request.destroy(fault('provider_timeout'));});
    request.on('error',()=>readFailure('provider_unavailable'));
    // The fetch deadline bounds receipt. Do not truncate a received business body before the audit consumer sees it.
    return request;
  };
  https.get=(...args)=>{const request=https.request(...args);request.end();return request;};
  // The pinned APIClient uses global fetch. Route it through the bundled
  // node-fetch (not Node's undici transport), so this HTTPS gate always runs.
  const fetchURL=require('node:url').pathToFileURL(path.resolve(__dirname,'../NetEase/node_modules/node-fetch/src/index.js')).href;
  global.fetch=async(url,options={})=>{
    const target=new URL(url);
    if(readContext?.cover&&target.hostname!=='openncm.music.163.com')return coverNOSFetch(url,options,fetchURL);
    const diagnosticPhase=readContext?.isWrite&&target.pathname===readContext.activePath?'effect':FiniteDiagnostics.phaseFor(target.pathname);
    if(diagnostic&&diagnostic.phase!==diagnosticPhase)diagnostic.record(diagnosticPhase,'started');
    const relevant=readContext&&target.hostname==='openncm.music.163.com'&&[MANIFEST_PATH,REFRESH_PATH,readContext.activePath,...(readContext.cover?[COVER_TOKEN_PATH]:[])].includes(target.pathname);
    let actualBusiness=null,actualBusinessText=null;
    if(relevant) {
      check(Object.keys(options).every(key=>['method','headers','body','signal'].includes(key)),'unexpected_fetch_options');
      check(object(options.headers)&&Object.entries(options.headers).every(([key,value])=>
        ['content-type','user-agent','referer','x-user-input'].includes(key.toLowerCase())&&typeof value==='string'&&value.length<=2048),'unexpected_fetch_headers');
      let signed;
      if(readContext.cover&&target.pathname===COVER_TOKEN_PATH) {
        check(options.method==='POST'&&options.body===undefined,'invalid_cover_token_method');
        signed={};for(const [key,value]of target.searchParams){check(!Object.hasOwn(signed,key),'duplicate_signed_query');signed[key]=value;}
      } else if(target.pathname===MANIFEST_PATH || target.pathname===readContext.activePath && readContext.activeMethod==='POST') {
        check(options.method==='POST'&&target.search===''&&typeof options.body==='string'&&Buffer.byteLength(options.body)<=(batchOperations.has(readContext.operation)?131072:32768),'invalid_manifest_request');
        signed=strictJSON(Buffer.from(options.body));
      } else {
        check(options.method==='GET'&&options.body===undefined,'invalid_read_http_method');
        signed={};for(const [key,value]of target.searchParams){check(!Object.hasOwn(signed,key),'duplicate_signed_query');signed[key]=value;}
      }
      check(keys(signed,Object.hasOwn(signed,'accessToken')?['appId','signType','timestamp','device','bizContent','accessToken','sign']:['appId','signType','timestamp','device','bizContent','sign'])&&
        (target.pathname===REFRESH_PATH||typeof signed.accessToken==='string'&&signed.accessToken.length>0)&&
        Object.entries(signed).every(([key,value])=>typeof value==='string'&&value.length<=(key==='bizContent'&&batchOperations.has(readContext.operation)?65536:16384))&&signed.bizContent.length<=(batchOperations.has(readContext.operation)?65536:4096),'invalid_signed_request');
      const business=strictJSON(Buffer.from(signed.bizContent));actualBusiness=business;actualBusinessText=signed.bizContent;
      if(target.pathname===MANIFEST_PATH)check(keys(business,['cliVersion','cachedVersion'])&&business.cliVersion==='0.1.7'&&business.cachedVersion==='{}','invalid_manifest_business');
      else if(target.pathname===REFRESH_PATH)check(keys(business,['clientId','clientSecret','refreshToken'])&&business.clientSecret===''&&
        typeof business.clientId==='string'&&typeof business.refreshToken==='string'&&business.refreshToken.length>0,'invalid_refresh_business');
      else if(readContext.cover)validateCoverBusiness(target.pathname,business);
      else check(keys(business,Object.keys(readContext.expectedBusiness))&&Object.entries(readContext.expectedBusiness).every(([key,value])=>
        business[key]===value||Array.isArray(value)&&Array.isArray(business[key])&&business[key].length===value.length&&business[key].every((item,i)=>item===value[i])||
        ['limit','offset','startTime','endTime'].includes(key)&&business[key]===Number(value)||
        libraryOperations.has(readContext.operation)&&['descFlag','qualityFlag'].includes(key)&&business[key]===(value==='true')),'read_business_mismatch');
    }
    if(libraryOperations.has(readContext?.operation)&&target.pathname===readContext.activePath)readContext.libraryParameters=actualBusiness;
    const exchangeStarted=performance.now();
    const exchange={path:target.pathname,method:String(options.method||'GET').toUpperCase(),
      parameters:actualBusiness??{},business_text:actualBusinessText,
      stage:readContext?.stage??'discovery'};
    if(relevant)businessEvidence('http_request',exchange);
    const controller=new AbortController();
    const abort=()=>controller.abort();
    const timer=setTimeout(abort,10000);
    options.signal?.addEventListener('abort',abort,{once:true});
    if(options.signal?.aborted)abort();
    let bytes,httpStatus,parseFailed=false;
    try {
      check(!controller.signal.aborted,'provider_aborted');
      const module=await import(fetchURL);
      check(!controller.signal.aborted,'provider_aborted');
      const response=await module.default(url,{...options,redirect:'error',size:0,signal:controller.signal});
      httpStatus=response.status;
      if(relevant) {
        if(target.pathname===MANIFEST_PATH)readContext.manifestHTTPStatus=httpStatus;
        if(target.pathname===readContext.activePath)readContext.activeHTTPStatus=httpStatus;
      }
      bytes=Buffer.from(await response.arrayBuffer()); // node-fetch enforces decompressed size too.
      let parsed;
      try { parsed=strictJSON(bytes); } catch(error) {
        if(relevant) {
          const record={...exchange,http_status:httpStatus,elapsed_ms:Math.round(performance.now()-exchangeStarted),
            received_bytes:bytes.length,...(target.pathname===COVER_TOKEN_PATH?{authentication_body_omitted:true}:businessBody(bytes)),failure_stage:'parse'};
          const recordID=businessEvidence('http_response',record);
          readContext.lastProviderResult=providerExchange(record,recordID);
        }
        parseFailed=true;throw error;
      }
      if(readContext?.cover&&[COVER_TOKEN_PATH,COVER_PATH].includes(target.pathname)) {
        const original=JSON.parse(bytes.toString('utf8'),(_key,value,context)=>
          typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?JSON.rawJSON(context.source):value);
        const safe=providerRecord(original);
        if(target.pathname===COVER_TOKEN_PATH) {
          acceptCoverToken(parsed,bytes,response.ok);
          readContext.cover.receipts.push(safe);
        } else {
          readContext.cover.response=safe;
          readContext.cover.providerRejected=!response.ok||![0,200].includes(parsed?.code)||parsed?.success===false||
            parsed?.subCode!==undefined&&parsed?.subCode!==null&&![0,200,'0','200'].includes(parsed.subCode);
        }
        parsed=JSON.parse(bytes.toString('utf8'),(_key,value,context)=>
          typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?context.source:value);
      }
      if(readContext&&!readContext.isWrite&&target.pathname===readContext.activePath&&response.ok) {
        if(libraryOperations.has(readContext.operation))readContext.libraryProviderJSON=bytes.toString('utf8');
        else rememberProviderRecords(bytes);
      }
      diagnostic?.response(diagnosticPhase,response.status,parsed);
      if(relevant) {
        const record={...exchange,http_status:httpStatus,elapsed_ms:Math.round(performance.now()-exchangeStarted),received_bytes:bytes.length,...(readContext?.cover&&[COVER_TOKEN_PATH,COVER_PATH].includes(target.pathname)?
          {body_text:JSON.stringify(providerRecord(JSON.parse(bytes.toString('utf8'),(_key,value,context)=>
            typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?JSON.rawJSON(context.source):value))),body_encoding:'utf8',authentication_omitted:true}:businessBody(bytes))};
        const recordID=businessEvidence('http_response',record);
        readContext.lastProviderResult=providerExchange(record,recordID,parsed);
        if(target.pathname===readContext.activePath) {
          const emptyKind=trackEmptyObservation(parsed,actualBusiness);
          if(emptyKind)readContext.lastTrackEmpty={...readContext.lastProviderResult,
            fields:{...readContext.lastProviderResult.fields,offset:Number(actualBusiness.offset),classification:emptyKind}};
          else if(![0,200,'0','200'].includes(parsed?.code)||parsed?.success===false||
             parsed?.subCode!==undefined&&parsed?.subCode!==null&&![0,200,'0','200'].includes(parsed.subCode))
            readContext.lastProviderIssue=readContext.lastProviderResult;
        }
      }
      check(bytes.length<=1048576,'provider_response_limit');
      // Observe the exact field consumed by pinned QrcodeLoginService.getQrcode.
      // Do not rewrite the response, infer login, or expose QR/key contents.
      if(!readContext&&diagnosticPhase==='qr_create'&&response.ok&&object(parsed)&&
         [0,200,'0','200'].includes(parsed.code)&&parsed.success!==false)diagnostic?.qrPayload(parsed);
      if(readContext&&!readContext.isWrite&&target.pathname===readContext.activePath&&object(parsed)&&parsed.code===200&&String(parsed.subCode)==='10007'&&parsed.data===null){
        readFailure('provider_rejected',{reason:'provider_resource_missing',stage:'provider_response',httpStatus,providerStatus:providerBusinessStatus(parsed)});
        throw fault('provider_resource_missing');
      }
      if(readContext&&(!response.ok||object(parsed)&&(Object.hasOwn(parsed,'code')&&(!Number.isSafeInteger(parsed.code)||![0,200].includes(parsed.code))||parsed.success===false))) {
        const refresh=new URL(url).pathname===REFRESH_PATH;
        if(refresh)readContext.refreshRejected=true;
        readFailure(refresh?'refresh_rejected':'provider_rejected',{reason:refresh?'refresh_rejected':'provider_rejected',stage:refresh?'session':'provider_response',httpStatus,...(!refresh&&!readContext.isWrite?{providerStatus:providerBusinessStatus(parsed)}:{})});
      }
      if(readContext&&target.pathname===MANIFEST_PATH&&response.ok&&!readContext.failure) {
        observeCloudCatalog(parsed);
        observeCloudMetadata(parsed);
        try { parsed=readContext.isWrite?projectWriteManifestReply(parsed):projectReadManifestReply(parsed); }
        catch(error) { readFailure('contract_rejected',{reason:'manifest_contract_rejected',stage:'manifest',localCode:READ_CONTRACT_CODES[error?.code],httpStatus});throw error; }
      }
      return {ok:response.ok,status:response.status,statusText:'',json:async()=>parsed,text:async()=>readContext?.cover?JSON.stringify(parsed):''};
    } catch(error) {
      if(relevant) {
        const failureRecord={...exchange,http_status:httpStatus??null,
          elapsed_ms:Math.round(performance.now()-exchangeStarted),failure_stage:parseFailed?'parse':'provider',
          failure_code:typeof error?.code==='string'?error.code:'provider_unavailable',
          ...(target.pathname===COVER_TOKEN_PATH&&error?.code==='invalid_cover_token_reply'&&error.coverTokenValidation?
            {cover_token_validation:error.coverTokenValidation}:{})};
        const recordID=businessEvidence('http_failure',failureRecord);
        if(readContext.cover&&(target.pathname===COVER_PATH&&!readContext.cover.response||
           target.pathname===COVER_TOKEN_PATH&&failureRecord.cover_token_validation))
          readContext.lastProviderResult=providerExchange(failureRecord,recordID);
      }
      if(parseFailed)diagnostic?.record(diagnosticPhase,'invalid_response',{http_status:httpStatus});
      else diagnostic?.error(error,diagnosticPhase,httpStatus);
      if(relevant&&!readContext.failure) {
        const rejected=parseFailed||error?.type==='max-size'||error?.type==='no-redirect'||['duplicate_json_key','invalid_json','json_depth_limit'].includes(error?.code);
        readFailure(rejected?'contract_rejected':'provider_unavailable',{reason:rejected?'provider_response_invalid':'provider_unavailable',stage:'provider_response',localCode:READ_CONTRACT_CODES[error?.code],httpStatus});
      }
      throw fault('provider_unavailable');
    } finally {clearTimeout(timer);options.signal?.removeEventListener('abort',abort);bytes?.fill(0);}
  };
  syncBuiltinESMExports();
}
// Selected GET reads share a closed descriptor. Provider display extensions
// never reach Commander or its preprocessor. Core route/auth/params remain
// checked by the unchanged validator and signed-business boundary.
// BEGIN CREATED_CONTRACT_SHAPE
// Observation only: no provider strings, admission changes or parameter sampling.
function createdContractShape(method) {
  const inactive=v=>v===undefined||v===null||object(v)&&Object.keys(v).length===0||Array.isArray(v)&&v.length===0;
  const mask=predicates=>predicates.reduce((bits,pass,i)=>bits+(pass?0:2**i),0);
  const params=method.parameters,array=Array.isArray(params),map=object(params);
  const entries=array?params:map?Object.entries(params):[];
  const count=entries.length;
  const complete=array||map?(count<=4096?0:1):2;
  const methodMask=mask([
    inactive(method.metadata),inactive(method.preprocess),
    !Object.hasOwn(method,'fixed_params')||keys(method.fixed_params,[]),
    array,array&&count<=2,
    typeof method.name==='string'&&/^[a-z][a-zA-Z0-9]{0,31}$/.test(method.name)&&method.name!=='$default',
    method.http_method==='GET',method.auth_required===true,
    !method.auth_provider||method.auth_provider==='netease',
    typeof method.path==='string',typeof method.path==='string'&&method.path.length<=256,
    typeof method.path==='string'&&/^\/openapi\/(?:music|v1)\/[a-zA-Z0-9/]+$/.test(method.path),
    typeof method.path==='string'&&!method.path.includes('//'),
    method.path==='/openapi/music/basic/playlist/created/get/v2'
  ]);
  const http=method.http_method===undefined?0:method.http_method==='GET'?1:method.http_method==='POST'?2:
    typeof method.http_method==='string'?3:method.http_method===null?4:5;
  const provider=method.auth_provider===undefined?0:method.auth_provider===null?1:method.auth_provider===false?2:
    method.auth_provider===0?3:method.auth_provider===''?4:method.auth_provider==='netease'?5:method.auth_provider?6:7;
  const kind=params===undefined?0:params===null?1:array?2:object(params)?3:4;
  let fieldMask=0,limit=0,offset=0,unknown=0,duplicates=0,metadata=0,transform=0,defaults=0,required=0,rejected=0,locations=0,types=0;
  // Never sample a prefix. Copy map entries for observation using the pinned
  // CLI precedence {name:key,...value}; never pass this copy to projection.
  if(complete===0)for(const entry of entries) {
    const field=array?entry:{name:entry[0],...entry[1]};
    if(!object(field)){fieldMask|=1;unknown++;rejected++;continue;}
    const known=['limit','offset'].includes(field.name);
    const duplicate=field.name==='limit'?limit>0:field.name==='offset'?offset>0:false;
    if(field.name==='limit')limit++;else if(field.name==='offset')offset++;else unknown++;
    if(duplicate)duplicates++;
    const metaOK=inactive(field.metadata),transformOK=inactive(field.transform);
    const defaultOK=!Object.hasOwn(field,'default')||field.default===null||['string','number','boolean'].includes(typeof field.default);
    const requiredOK=field.required===undefined||typeof field.required==='boolean';
    const locationPredicates=[field.in==='query'||field.location==='query',!field.in||field.in==='query',
      !field.location||field.location==='query',!field.in||!field.location||field.in===field.location];
    const typeOK=['string','number','integer','boolean'].includes(field.type);
    const failures=mask([true,metaOK,transformOK,defaultOK,requiredOK,known,!duplicate,...locationPredicates,typeOK]);
    fieldMask|=failures;metadata+=!metaOK;transform+=!transformOK;defaults+=!defaultOK;required+=!requiredOK;
    rejected+=failures!==0;locations+=!locationPredicates.every(Boolean);types+=!typeOK;
  }
  return [[-97100,3],[-97101,methodMask],[-97102,http],[-97103,provider],[-97104,kind],
    [-97105,Math.min(count,4097)],[-97106,complete===0?count:0],[-97107,fieldMask],
    [-97108,limit],[-97109,offset],[-97110,unknown],[-97111,duplicates],
    [-97112,complete===0?(limit===0?1:0)+(offset===0?2:0):4],
    [-97113,metadata],[-97114,transform],[-97115,defaults],[-97116,required],
    [-97117,rejected],[-97118,locations],[-97119,types],[-97120,complete]];
}
function recordCreatedContractShape(method) {
  if(readContext?.operation!=='user_playlists'||readContext.isWrite||readContext.createdContractObserved||!diagnostic)return;
  readContext.createdContractObserved=true;
  const prior={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try {
    // Reserve the entire fixed series plus one original guard diagnostic. An explicit incomplete marker replaces a
    // partial series; a full existing cap produces no claim of completeness.
    if(!Number.isSafeInteger(diagnostic.count)||diagnostic.count>106) {
      diagnostic.record('bridge','ignored',{code:-97120,sub_code:3});return;
    }
    for(const [code,sub_code]of createdContractShape(method))diagnostic.record('bridge','ignored',{code,sub_code});
  } catch {
    try{diagnostic.record('bridge','ignored',{code:-97120,sub_code:4});}catch{}
  } finally {
    diagnostic.phase=prior.phase;diagnostic.last=prior.last;diagnostic.lastValues=prior.lastValues;
  }
}
// END CREATED_CONTRACT_SHAPE
// Retain the created-only entry used by earlier focused fixtures. All product
// GET reads now use one projection before Commander/cache/HTTPS consumption.
function projectCreatedManifestReply(reply) {
  check(readContext?.operation==='user_playlists'&&!readContext.isWrite,'invalid_manifest');
  return projectReadManifestReply(reply);
}
// BEGIN CLOUD_CATALOG_OBSERVATION
// Public command schema only, from the authenticated manifest already fetched
// by the official CLI. Never reads cloud songs or changes the admitted command.
function cloudCatalogObservation(reply) {
  const invalid={state:'invalid'},all=reply?.manifests,root=all?.root;
  if(!object(all)||Object.keys(all).length>128||!object(root)||
     !Array.isArray(root.sub_resources)||root.sub_resources.length>128)return invalid;
  const matches=[];
  for(const ref of root.sub_resources) {
    if(!object(ref)||typeof ref.path!=='string')return invalid;
    const group=all[ref.path];
    if(!object(group)||!Array.isArray(group.methods)||group.methods.length>128)return invalid;
    for(const method of group.methods) {
      if(object(method)&&method.path==='/openapi/music/basic/private/cloud/song/list/get')
        matches.push({group:ref.name,method});
    }
  }
  if(matches.length===0)return {state:'missing'};
  if(matches.length!==1)return {state:'ambiguous'};
  const {group,method}=matches[0],name=/^[a-z][a-zA-Z0-9_]{0,31}$/;
  if(typeof group!=='string'||name.exec(group)?.[0]!==group||typeof method.name!=='string'||name.exec(method.name)?.[0]!==method.name||
     !Array.isArray(method.parameters)||method.parameters.length>128)return invalid;
  const parameters=method.parameters;
  if(parameters.some(p=>!object(p))||
     ['offset','limit'].some(n=>parameters.filter(p=>p.name===n).length>1))return invalid;
  const known=(v,allowed)=>allowed.includes(v)?v:'unknown';
  const flag=v=>v===true?'true':v===false?'false':'unknown';
  const result={state:'observed',group,command:method.name,
    http_method:known(method.http_method,['GET','POST']),
    auth_required:flag(method.auth_required),
    parameter_count:String(parameters.length),
    extra_required_parameters:String(parameters.filter(p=>!['offset','limit'].includes(p.name)&&p.required!==false).length)};
  for(const key of ['offset','limit']) {
    const p=parameters.find(p=>p.name===key);
    result[key+'_type']=p?known(p.type,['integer','number','string','boolean','array','object']):'missing';
    result[key+'_required']=p?flag(p.required):'missing';
    const location=p?.in??p?.location;
    result[key+'_location']=!p?'missing':p.in&&p.location&&p.in!==p.location?'conflict':
      known(location,['query','body','path']);
  }
  return result;
}
function observeCloudCatalog(reply) {
  if(!readContext||readContext.isWrite||readContext.operation!=='search'||
     readContext.cloudCatalogObserved||!diagnostic)return;
  readContext.cloudCatalogObserved=true;
  const prior={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try {
    const value=cloudCatalogObservation(reply);
    if(secretFreeProjection(value))diagnostic.record('provider','ignored',{cloud_catalog:value});
  } catch {
    // Observation cannot turn an otherwise supported search into a failure.
  } finally {diagnostic.phase=prior.phase;diagnostic.last=prior.last;diagnostic.lastValues=prior.lastValues;}
}
// END CLOUD_CATALOG_OBSERVATION

// BEGIN CLOUD_METADATA_OBSERVATION
// Reusable bounded operation/schema observation, not an arbitrary catalog dump.
function cloudMetadataObservation(reply) {
  const out={schema_version:1,coverage:'complete',scanned_methods:0,matched_methods:0,
    omitted_candidates:0,skipped_groups:0,uninspectable_methods:0,entries:[]};
  const all=reply?.manifests;
  if(!object(all)||Object.keys(all).length>128||!object(all.root))
    return {...out,coverage:'invalid',skipped_groups:1};
  const token=v=>typeof v==='string'&&/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.exec(v)?.[0]===v;
  const endpoint=v=>typeof v==='string'&&v.length<=256&&/^\/openapi\/[A-Za-z0-9_/{}:-]+$/.exec(v)?.[0]===v;
  const known=(v,allowed)=>allowed.includes(v)?v:'unknown';
  const flag=v=>v===true?'true':v===false?'false':'unknown';
  const semantic=/(?:cloud|private|user.*asset|asset.*user|云盘|网盘|用户资产)/i;
  const description=v=>typeof v==='string'&&v.length<=2048?v:'';
  const queue=[{path:'root',operation:[]}],visited=new Set();
  while(queue.length) {
    const next=queue.shift();
    if(visited.has(next.path)||visited.size>=128||next.operation.length>4) {out.skipped_groups++;continue;}
    visited.add(next.path);
    const group=Object.hasOwn(all,next.path)?all[next.path]:null;
    if(!object(group)) {out.skipped_groups++;continue;}
    const methods=group.methods??[];
    if(!Array.isArray(methods)||methods.length>128) {out.skipped_groups++;continue;}
    for(const method of methods) {
      out.scanned_methods++;
      if(!object(method)) {out.uninspectable_methods++;continue;}
      // Count once per method when either description cannot be fully inspected.
      if([method.description,group.description].some(v=>v!=null&&(typeof v!=='string'||v.length>2048)))
        out.uninspectable_methods++;
      const text=[...next.operation,typeof method.name==='string'?method.name:'',
        typeof method.path==='string'?method.path:'',description(method.description),description(group.description)].join(' ');
      if(!semantic.test(text))continue;
      out.matched_methods++;
      if(!token(method.name)||!endpoint(method.path)) {
        out.omitted_candidates++;continue;
      }
      const parameters=Array.isArray(method.parameters)&&method.parameters.length<=128?method.parameters:null;
      const entry={operation:[...next.operation,method.name],endpoint:method.path,
        http_method:known(method.http_method,['GET','POST','PUT','DELETE','PATCH','HEAD','OPTIONS']),
        auth_required:flag(method.auth_required),parameter_count:parameters?.length??-1,schema_complete:true,parameters:[]};
      entry.schema_complete=parameters!==null&&entry.http_method!=='unknown'&&entry.auth_required!=='unknown';
      for(const p of parameters??[]) {
        if(!object(p)||!token(p.name)||entry.parameters.length>=16) {entry.schema_complete=false;continue;}
        const location=p.in??p.location;
        const field={name:p.name,type:known(p.type,['integer','number','string','boolean','array','object','file']),
          location:p.in&&p.location&&p.in!==p.location?'conflict':known(location,['query','body','path','header']),
          required:flag(p.required)};
        if(field.type==='unknown'||['unknown','conflict'].includes(field.location)||field.required==='unknown')
          entry.schema_complete=false;
        entry.parameters.push(field);
      }
      if(new Set(entry.parameters.map(p=>p.name)).size!==entry.parameters.length)entry.schema_complete=false;
      const trial={...out,scanned_methods:16384,matched_methods:16384,omitted_candidates:16384,
        skipped_groups:16384,uninspectable_methods:16384,entries:[...out.entries,entry]};
      if(out.entries.length>=24||Buffer.byteLength(JSON.stringify(trial))>8000||!secretFreeProjection(entry))out.omitted_candidates++;
      else out.entries.push(entry);
    }
    const children=group.sub_resources??[];
    if(!Array.isArray(children)||children.length>128) {out.skipped_groups++;continue;}
    for(const ref of children) {
      if(!object(ref)||!token(ref.name)||typeof ref.path!=='string'||ref.path.length>128||
         !Object.hasOwn(all,ref.path)) {out.skipped_groups++;continue;}
      queue.push({path:ref.path,operation:[...next.operation,ref.name]});
    }
  }
  if(out.omitted_candidates||out.skipped_groups||out.uninspectable_methods||out.entries.some(e=>!e.schema_complete))
    out.coverage='partial';
  return out;
}
function observeCloudMetadata(reply) {
  if(!readContext||readContext.isWrite||readContext.operation!=='search'||
     readContext.cloudMetadataObserved||!diagnostic)return;
  readContext.cloudMetadataObserved=true;
  const prior={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try {
    const value=cloudMetadataObservation(reply);
    if(secretFreeProjection(value))diagnostic.record('provider','ignored',{cloud_metadata:value});
  } catch {
    // Metadata observations cannot change admission or a business result.
  } finally {diagnostic.phase=prior.phase;diagnostic.last=prior.last;diagnostic.lastValues=prior.lastValues;}
}
// END CLOUD_METADATA_OBSERVATION

function requiredReadStages(operation,metadataOnly=false) {
  return operation==='playlist_detail'&&!metadataOnly?['playlist_detail','tracks']:[operation];
}
function projectReadManifestReply(reply) {
  check(readContext&&readOperations.has(readContext.operation)&&!readContext.isWrite,'invalid_manifest');
  check(object(reply)&&object(reply.manifests)&&Object.keys(reply.manifests).length<=128,'invalid_manifest');
  const all=reply.manifests,root=all.root;
  check(object(root)&&Array.isArray(root.sub_resources)&&root.sub_resources.length<=128,'invalid_manifest_root');
  // Build the exact command we consume. Unused provider annotations, defaults
  // and transforms are neither interpreted nor passed to Commander.
  const result={notices:[],manifests:{root:{methods:[],sub_resources:[]}}};
  const selected=requiredReadStages(readContext.operation,readContext.metadataOnly);
  for(const operation of selected) {
    const spec=READ_SPECS[operation];
    const groups=root.sub_resources.filter(row=>object(row)&&row.name===spec.group);
    check(groups.length===1&&typeof groups[0].path==='string'&&groups[0].path.length<=128&&
      !['root','__proto__','prototype','constructor'].includes(groups[0].path),'ambiguous_read_group');
    const groupPath=groups[0].path,group=all[groupPath];
    check(Object.hasOwn(all,groupPath)&&object(group)&&Array.isArray(group.methods)&&group.methods.length<=128,'missing_read_group');
    const matches=group.methods.filter(row=>object(row)&&(spec.method?row.name===spec.method:row.path===spec.path));
    check(matches.length===1,'ambiguous_read_method');
    const method=matches[0];
    if(operation==='cloud_songs')validateCloudSongDescriptor(method);
    if(operation==='user_playlists')recordCreatedContractShape(method);
    // GET in the pinned CLI uses queryParams only; fixed_params enters only
    // bodyParams. No effect/POST descriptor ever enters this projection.
    let fields=method.parameters;
    if(object(fields)) {
      check(Object.keys(fields).length<=128,'invalid_read_method');
      fields=Object.entries(fields).map(([name,value])=>{
        check(object(value),'invalid_read_parameter');return {name,...value};
      });
    }
    check(Array.isArray(fields)&&fields.length<=128,'invalid_read_method');
    const supplied=libraryOperations.has(operation)?Object.keys(readContext.arguments):operation==='search'?['keyword','limit','offset']:operation==='cloud_songs'?['cursor','limit']:
      operation==='playlist_detail'?['playlistId']:operation==='tracks'?['playlistId','limit','offset']:['limit','offset'];
    const names=new Set(),parameters=[];
    for(const field of fields) {
      check(object(field)&&typeof field.name==='string'&&/^[a-z][a-zA-Z0-9]{0,63}$/.test(field.name)&&
        !['__proto__','prototype','constructor'].includes(field.name)&&!names.has(field.name),'invalid_read_parameter');
      names.add(field.name);
      check(field.required===undefined||field.required===null||typeof field.required==='boolean','invalid_read_parameter');
      if(!supplied.includes(field.name)) {
        check(field.required!==true,'invalid_read_parameter');continue;
      }
      // Owner supplies every retained value. Discard all provider defaults and
      // display attributes rather than allowing them to alter the command.
      const value={name:field.name,type:field.type,required:field.required===true};
      if(Object.hasOwn(field,'in'))value.in=field.in;
      if(Object.hasOwn(field,'location'))value.location=field.location;
      parameters.push(value);
    }
    const projected={name:method.name,description:'Read selected music data',http_method:method.http_method,
      auth_required:method.auth_required,path:method.path,parameters};
    if(Object.hasOwn(method,'auth_provider'))projected.auth_provider=method.auth_provider;
    if(!Object.hasOwn(result.manifests,groupPath)) {
      result.manifests.root.sub_resources.push({name:spec.group,path:groupPath});
      result.manifests[groupPath]={methods:[],sub_resources:[]};
    }
    check(!result.manifests[groupPath].methods.some(item=>item.name===projected.name),'ambiguous_read_method');
    result.manifests[groupPath].methods.push(projected);
  }
  // This exact mapping drives fixed argv, activePath/activeMethod and the signed
  // business equality checks in both network gates. Their policies are unchanged.
  validateManifests(result);
  return result;
}
// The pinned CLI converts body array options to arrays; query options stay scalar.
// Only one owner-selected song is admitted, never provider defaults or extra IDs.
function appendArrayParameter(operation,field) {
  return (['playlist_append','playlist_add_songs','playlist_remove_songs'].includes(operation)&&field.name==='songIdList'||operation==='playlist_reorder'&&field.name==='trackIds')&&field.type==='array';
}
function appendBodyArray(operation,method,field) {
  return appendArrayParameter(operation,field)&&method.http_method==='POST'&&(field.in||field.location)==='body';
}
// Effects use the official declared GET/POST method. Read/write semantics come from the fixed intent.
function projectWriteManifestReply(reply) {
  check(readContext?.isWrite&&writeOperations.has(readContext.operation),'invalid_manifest');
  check(object(reply)&&object(reply.manifests)&&Object.keys(reply.manifests).length<=128,'invalid_manifest');
  const all=reply.manifests,root=all.root,spec=READ_SPECS[readContext.operation];
  check(object(root)&&Array.isArray(root.sub_resources)&&root.sub_resources.length<=128,'invalid_manifest_root');
  const groups=root.sub_resources.filter(row=>object(row)&&row.name===spec.group);
  check(groups.length===1&&typeof groups[0].path==='string'&&groups[0].path.length<=128&&
    !['root','__proto__','prototype','constructor'].includes(groups[0].path),'ambiguous_read_group');
  const groupPath=groups[0].path,group=all[groupPath];
  check(Object.hasOwn(all,groupPath)&&object(group)&&Array.isArray(group.methods)&&group.methods.length<=128,'missing_read_group');
  const methods=group.methods.filter(row=>object(row)&&row.name===spec.method);
  check(methods.length===1,'ambiguous_read_method');
  const method=methods[0];
  check(['GET','POST'].includes(method.http_method),'invalid_write_http_method');
  let fields=method.parameters;
  if(object(fields))fields=Object.entries(fields).map(([name,value])=>{
    check(object(value)&&(!Object.hasOwn(value,'name')||value.name===name),'invalid_write_parameter_name');return {name,...value};
  });
  check(Array.isArray(fields)&&fields.length<=128,'invalid_write_parameter_shape');
  const parameters=[],names=new Set();
  for(const field of fields) {
    check(object(field)&&typeof field.name==='string'&&!names.has(field.name),'invalid_write_parameter_name');
    names.add(field.name);
    if(!spec.fields.includes(field.name)) {
      check(field.required!==true,'unsupported_required_write_parameter');continue;
    }
    check(field.type==='string'||readContext.operation==='playlist_cover'&&field.name==='picIds'&&field.type==='imgs_file_upload'||appendArrayParameter(readContext.operation,field),'invalid_write_parameter_type');
    // Owner supplies the target and values. Optional unused fields are omitted.
    const value={name:field.name,type:field.type,required:true};
    if(Object.hasOwn(field,'in'))value.in=field.in;
    if(Object.hasOwn(field,'location'))value.location=field.location;
    parameters.push(value);
  }
  // Provider fixed defaults are not consumed or forwarded. All signed business
  // values below come only from the explicit owner arguments.
  const projected={name:method.name,http_method:method.http_method,auth_required:method.auth_required,
    path:method.path,parameters,description:'Apply the explicit playlist intent'};
  if(Object.hasOwn(method,'auth_provider'))projected.auth_provider=method.auth_provider;
  const result={notices:[],manifests:{root:{methods:[],sub_resources:[{name:spec.group,path:groupPath}]},
    [groupPath]:{methods:[projected],sub_resources:[]}}};
  validateManifests(result);
  return result;
}

function validateManifests(cache) {
  check(object(cache)&&object(cache.manifests)&&Object.keys(cache.manifests).length<=128,'invalid_manifest');
  const all=cache.manifests,root=all.root;
  check(object(root)&&Array.isArray(root.sub_resources),'invalid_manifest_root');
  const selected={};
  for(const operation of (requiredReadStages(readContext.operation,readContext.metadataOnly))) {
    const spec=READ_SPECS[operation];
    const groups=root.sub_resources.filter(row=>object(row)&&row.name===spec.group);
    check(groups.length===1&&typeof groups[0].path==='string'&&groups[0].path.length<=128,'ambiguous_read_group');
    const group=all[groups[0].path];
    check(object(group)&&Array.isArray(group.methods)&&group.methods.length<=128,'missing_read_group');
    const candidates=group.methods.filter(row=>object(row)&&(spec.method?row.name===spec.method:row.path===spec.path));
    check(candidates.length===1,'ambiguous_read_method');
    const method=candidates[0];
    const contractCheck=(ok,rule)=>check(ok,spec.effect?rule:'invalid_read_method');
    contractCheck(typeof method.name==='string'&&/^[a-z][a-zA-Z0-9]{0,31}$/.test(method.name)&&method.name!=='$default','invalid_write_name');
    contractCheck((spec.library||metadataOperations.has(operation)||batchOperations.has(operation))?method.http_method===spec.httpMethod:spec.effect?['GET','POST'].includes(method.http_method):method.http_method==='GET','invalid_write_http_method');
    contractCheck(method.auth_required===true&&(!method.auth_provider||method.auth_provider==='netease'),'invalid_write_auth');
    contractCheck(typeof method.path==='string'&&method.path.length<=256&&/^\/openapi\/(?:music|v1)\/[a-zA-Z0-9/]+$/.test(method.path)&&
      !method.path.includes('//')&&(!spec.path||method.path===spec.path)&&
      (operation!=='search'||method.path.split('/').includes('search')&&method.path.split('/').includes('song'))&&
      // The authenticated official add descriptor uses /song/batch/like.
      // Pin that observed route; a command name need not be a URL segment.
      (!spec.effect||((['playlist_append','playlist_cover'].includes(operation)||metadataOperations.has(operation)||batchOperations.has(operation))?method.path===spec.path:
        method.path.split('/').includes('playlist')&&method.path.split('/').includes(spec.method))),'invalid_write_route');
    contractCheck(Array.isArray(method.parameters)&&method.parameters.length<=spec.fields.length&&
      (!Object.hasOwn(method,'fixed_params')||(spec.effect?object(method.fixed_params)&&Object.entries(method.fixed_params).every(([key,value])=>
        Object.hasOwn(metadataOperations.has(readContext.operation)?metadataValues(readContext.operation,readContext.arguments):readContext.operation==='playlist_create'?{playlistName:readContext.arguments.name}:{playlistId:readContext.arguments.playlist_id,songIdList:readContext.arguments.song_id},key)&&
        value===(metadataOperations.has(readContext.operation)?metadataValues(readContext.operation,readContext.arguments):readContext.operation==='playlist_create'?{playlistName:readContext.arguments.name}:{playlistId:readContext.arguments.playlist_id,songIdList:readContext.arguments.song_id})[key]):keys(method.fixed_params,[])))&&
      !Object.hasOwn(method,'metadata')&&!Object.hasOwn(method,'preprocess'),'invalid_write_projected_fields');
    const names=new Set(),arrayFields=new Set();
    const locations=spec.effect&&method.http_method==='POST'?['query','body']:['query'];
    for(const field of method.parameters) {
      const parameterCheck=(ok,rule)=>check(ok,spec.effect?rule:'invalid_read_parameter');
      parameterCheck(object(field)&&Object.keys(field).every(key=>['name','in','location','type','required','description','hidden'].includes(key))&&
        spec.fields.includes(field.name)&&!names.has(field.name),'invalid_write_parameter_name');
      parameterCheck((locations.includes(field.in)||locations.includes(field.location))&&(!field.in||locations.includes(field.in))&&
        (!field.location||locations.includes(field.location))&&(!field.in||!field.location||field.in===field.location),'invalid_write_parameter_location');
      parameterCheck(spec.effect?(field.type==='string'||operation==='playlist_cover'&&field.name==='picIds'&&field.type==='imgs_file_upload'||appendArrayParameter(operation,field)):
        ['string','number','integer','boolean'].includes(field.type),'invalid_write_parameter_type');
      if(batchOperations.has(operation))parameterCheck(field.type===(field.name==='playlistId'||operation==='playlist_update_tags'?'string':'array'),'invalid_write_parameter_type');
      if(appendArrayParameter(operation,field)&&method.http_method==='POST')arrayFields.add(field.name);
      if(operation==='cloud_songs')check(field.type===(field.name==='limit'?'number':'string')&&field.required===false,'invalid_read_parameter');
      if(operation==='search'&&['limit','offset'].includes(field.name))check(['number','integer'].includes(field.type),'invalid_search_pagination_type');
      if(spec.library)parameterCheck(field.type===spec.types[field.name]&&(field.in||field.location)==='query','invalid_write_parameter_type');
      names.add(field.name);
    }
    if(batchOperations.has(operation))check(method.parameters.every(field=>(field.in||field.location)===(operation==='playlist_reorder'?'body':'query')),'invalid_write_parameter_location');
    if(operation==='playlist_cover')check(method.http_method==='POST'&&method.parameters.every(field=>
      field.in==='query'&&!field.location&&(field.name==='picIds'?field.type==='imgs_file_upload':field.type==='string')),'invalid_cover_manifest');
    const required=spec.library?spec.required:spec.effect?spec.fields:operation==='cloud_songs'?['cursor','limit']:operation==='search'?['keyword','limit']:operation==='playlist_detail'?['playlistId']:operation==='tracks'?['playlistId','limit','offset']:['limit','offset'];
    if(spec.library)check(Object.keys(readContext.arguments).every(name=>names.has(name)),'missing_read_parameter');
    check(required.every(name=>names.has(name)),spec.effect?'missing_write_parameter':'missing_read_parameter');
    // The public request selects only this fixed command. The reviewed dynamic
    // GET path is held in memory and becomes the sole admitted consume endpoint.
    selected[operation]={group:spec.group,name:method.name,path:method.path,httpMethod:method.http_method,names,arrayFields};
  }
  return selected;
}
function inspectSession() {
  const stored=files.get('.config/ncm-cli/tokens.enc.json');
  if(!stored)return {present:false,refreshable:false};
  const device=strictJSON(files.get('.netease_mcp_device.json')).deviceId;
  const value=strictJSON(stored),key=crypto.createHash('sha256').update(device).digest();
  let plain;
  try {
    const decipher=crypto.createDecipheriv('aes-256-cbc',key,Buffer.from(value.iv,'hex'));
    plain=Buffer.concat([decipher.update(Buffer.from(value.data,'hex')),decipher.final()]);
    const token=strictJSON(plain);
    return {present:typeof token.namedToken==='string'&&token.namedToken.length>0&&Number.isSafeInteger(token.namedTokenExpireAt)&&token.namedTokenExpireAt>Date.now(),
      refreshable:typeof token.namedRefreshToken==='string'&&token.namedRefreshToken.length>0&&Number.isSafeInteger(token.namedTokenExpireAt)};
  } finally { key.fill(0);plain?.fill(0); }
}
// Numeric-only search diagnostics. No text, IDs, hashes, URLs or provider scalars.
function readText(value,limit,field=0,rowIndex=-1) {
  const isText=typeof value==='string',bytes=isText?Buffer.byteLength(value):0;
  const mask=(!isText?1:0)|(isText&&value.trim().length===0?2:0)|(isText&&bytes>limit?4:0)|(isText&&/[\x00-\x1f\x7f]/.test(value)?8:0);
  if(mask&&readContext&&!readContext.isWrite&&readContext.operation==='search'&&diagnostic&&
     Number.isInteger(field)&&field>=1&&field<=4&&Number.isInteger(rowIndex)&&rowIndex>=0&&rowIndex<20) {
    const type=isText?1:value===null?2:value===undefined?3:Array.isArray(value)?4:object(value)?5:typeof value==='number'?6:7;
    const previous={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
    try {
      diagnostic.record('bridge','ignored',{code:-97500,sub_code:field*10000+(rowIndex+1)*256+mask*8+type});
      diagnostic.record('bridge','ignored',{code:-97501,sub_code:Math.min(999999,bytes)});
      diagnostic.record('bridge','ignored',{code:-97502,sub_code:limit});
    } catch {} finally {Object.assign(diagnostic,previous);}
  }
  check(mask===0,'invalid_result_text');return value.trim();
}
function readID(value) {check(typeof value==='string'&&/^[a-f0-9]{32}$/i.test(value),'invalid_encrypted_id');return value.toLowerCase();}
// Only fields consumed by the pinned official CLI are mapped. It contains no
// authoritative recording-version field or unambiguous duration-unit contract.
function strictSongMetadata(value,rowIndex=-1) {
  const candidates=value.ar??value.artists;
  let artists=null,album=null;
  if(candidates!==undefined&&candidates!==null) {
    check(Array.isArray(candidates)&&candidates.length<=20,'invalid_song_artists');
    artists=candidates.length?candidates.map(row=>readText(typeof row==='string'?row:object(row)?row.name:undefined,200,3,rowIndex)):null;
  }
  const record=value.al??value.album;
  if(record!==undefined&&record!==null)album=readText(typeof record==='string'?record:object(record)?record.name:undefined,400,4,rowIndex);
  return {artists,album,recording_version:null,duration_ms:null,
    unknown_fields:[...(artists===null?['artists']:[]),...(album===null?['album']:[]),'recording_version','duration_ms']};
}
// Optional public metadata is not a song identity requirement. Missing or
// unsupported scalar forms remain explicitly unknown; no inferred names/units.
function optionalSongText(value,limit) {
  if(typeof value!=='string'||Buffer.byteLength(value)>limit)return null;
  const display=value.replace(/\r\n|[\r\n\t]/g,' ').trim();
  return display.length&&!/[\x00-\x1f\x7f]/.test(display)?display:null;
}
function songMetadata(value,rowIndex=-1) {
  // Effect/readback contracts retain their reviewed strict behavior.
  if(readContext?.isWrite)return strictSongMetadata(value,rowIndex);
  // Official keyword-song contract: fullArtists includes offline artists.
  // Null/empty primary lists do not swallow a supplied nonempty fallback.
  const artistField=['fullArtists','ar','artists'].find(k=>Array.isArray(value[k])&&value[k].length>0);
  const candidates=artistField?value[artistField]:null,record=value.al??value.album;
  let artists=null,album=null;
  if(Array.isArray(candidates)&&candidates.length>0&&candidates.length<=20) {
    const names=candidates.map(row=>optionalSongText(typeof row==='string'?row:object(row)?row.name:undefined,200));
    // Do not present a partial artist list as complete when any name is unknown.
    if(names.every(name=>name!==null))artists=names;
  }
  album=optionalSongText(typeof record==='string'?record:object(record)?record.name:undefined,400);
  // Official doc b175e0d52550427cbb7cd4735a9de765: 0 unknown, 1 original
  // performer, 2 cover. This is not a studio/live/remaster recording identity.
  const origin=Number.isInteger(value.originCoverType)&&[0,1,2].includes(value.originCoverType)?value.originCoverType:null;
  const version=origin===1?'original_performer':origin===2?'cover':null;
  return {artists,album,recording_version:version,origin_cover_type:origin,duration_ms:null,
    unknown_fields:[...(artists===null?['artists']:[]),...(album===null?['album']:[]),...(version===null?['recording_version']:[]),'duration_ms']};
}
// Read-only, versioned business projection. No arbitrary provider objects/text.
const BUSINESS_BOOL_FIELDS=['playFlag','privateCloudSong','downloadFlag','payPlayFlag','payDownloadFlag','vipFlag','vipPlayFlag','freeTrailFlag','freeTrialFlag','vocalFlag','songFtFlag','accompanyFlag'];
const BUSINESS_INT_FIELDS=['songFee','songMaxBr','userMaxBr','playMaxbr'];
const BUSINESS_LEVEL_FIELDS=['maxBrLevel','plLevel','dlLevel'];
function songBusinessInfo(value) {
  const unknown={},flags={};
  const missing=(raw,present)=>!present?'not_in_response':raw===null?'upstream_null':typeof raw==='string'&&!raw.trim()?'empty_value':'invalid_shape';
  const readTextFact=(raw,field,present,limit)=>{
    const text=optionalSongText(raw,limit);
    if(text===null)unknown[field]=typeof raw==='string'&&Buffer.byteLength(raw)>limit?'local_limit':missing(raw,present);
    return text;
  };
  const entity=(raw,field,present)=>{
    const row=object(raw)?raw:{name:typeof raw==='string'?raw:null};
    let id=null,id_type=null;
    if(typeof row.id==='string'&&(/^[a-f0-9]{32}$/i.test(row.id)||/^[1-9][0-9]{0,19}$/.test(row.id))){id=row.id;id_type='string';}
    else if(Number.isSafeInteger(row.id)&&row.id>0){id=String(row.id);id_type='integer';}
    else unknown[field+'.id']=missing(row.id,present&&Object.hasOwn(row,'id'));
    const name=readTextFact(row.name,field+'.name',present&&Object.hasOwn(row,'name'),field==='album'?400:200);
    return {id,id_source_type:id_type,name};
  };
  const artistField=['fullArtists','ar','artists'].find(k=>Array.isArray(value[k])&&value[k].length>0)??['fullArtists','ar','artists'].find(k=>Object.hasOwn(value,k));
  const rawArtists=artistField?value[artistField]:undefined;
  let artists=null;
  if(Array.isArray(rawArtists)&&rawArtists.length>0&&rawArtists.length<=20)artists=rawArtists.map((row,i)=>entity(row,'artists['+i+']',true));
  else unknown.artists=Array.isArray(rawArtists)&&rawArtists.length>20?'local_limit':missing(rawArtists,!!artistField);
  const albumField=['al','album'].find(k=>value[k]!==null&&value[k]!==undefined)??['al','album'].find(k=>Object.hasOwn(value,k));
  const rawAlbum=albumField?value[albumField]:undefined;
  let album=null;
  if(object(rawAlbum)||typeof rawAlbum==='string')album=entity(rawAlbum,'album',true);
  else unknown.album=missing(rawAlbum,!!albumField);
  let duration=null;
  if(Number.isSafeInteger(value.duration)&&value.duration>=0)duration=value.duration;
  else unknown.duration_raw=missing(value.duration,Object.hasOwn(value,'duration'));
  unknown.duration_unit='unit_unconfirmed';unknown.recording_edition='not_requested';
  for(const field of ['qualities','songTag','emotionTag'])unknown[field]=Object.hasOwn(value,field)?value[field]===null?'upstream_null':'not_mapped':'not_in_response';
  const origin=Number.isInteger(value.originCoverType)&&[0,1,2].includes(value.originCoverType)?value.originCoverType:null;
  if(origin===null)unknown.origin_cover_type=missing(value.originCoverType,Object.hasOwn(value,'originCoverType'));
  for(const key of BUSINESS_BOOL_FIELDS){if(typeof value[key]==='boolean')flags[key]=value[key];else unknown['provider_flags.'+key]=missing(value[key],Object.hasOwn(value,key));}
  for(const key of BUSINESS_INT_FIELDS){if(Number.isSafeInteger(value[key])&&value[key]>=0)flags[key]=value[key];else unknown['provider_flags.'+key]=missing(value[key],Object.hasOwn(value,key));}
  for(const key of BUSINESS_LEVEL_FIELDS){if(typeof value[key]==='string'&&/^[a-z][a-z0-9_]{0,31}$/.test(value[key]))flags[key]=value[key];else unknown['provider_flags.'+key]=missing(value[key],Object.hasOwn(value,key));}
  const trial=value.freeTrialPrivilege;
  for(const key of ['resConsumable','userConsumable','cannotListenReason']){
    const raw=object(trial)?trial[key]:undefined,field='freeTrialPrivilege.'+key;
    if(key==='cannotListenReason'?Number.isSafeInteger(raw)&&raw>=0:typeof raw==='boolean')flags[field]=raw;
    else unknown['provider_flags.'+field]=missing(raw,object(trial)&&Object.hasOwn(trial,key));
  }
  return {schema_version:1,source_operation:['search','tracks','cloud_songs'].includes(readContext?.stage)?readContext.stage:['search','cloud_songs'].includes(readContext?.operation)?readContext.operation:'tracks',
    artists,artists_source_field:artistField??null,album,album_source_field:albumField??null,duration_raw:duration,duration_unit:null,duration_source_field:'duration',
    origin_cover_category:origin===1?'original_performer':origin===2?'cover':'unknown',recording_edition:null,
    legacy_recording_version_semantics:'origin_cover_classification',availability_semantics:'provider_flags_only',provider_flags:flags,unknown_reasons:unknown};
}
// Preserve business JSON independently of compatibility metadata. Never copy the
// response/authentication envelope. Recursive credential fields and signed URLs
// are omitted explicitly; known session material is checked again before output.
const PROVIDER_AUTH_KEYS=new Set(['accesstoken','refreshtoken','authtoken','idtoken','sessionkey','namedtoken','namedrefreshtoken','token','privatekey','apikey','clientsecret','password','authorization','proxyauthorization','cookie','setcookie','xflyaisign','xffctx']);
const PROVIDER_AUTH_CONTEXTS=new Set(['auth','authentication','oauth','credentials','credential','headers','requestheaders']);
const PROVIDER_AUTH_CONTEXT_KEYS=new Set(['session','sessionid','secret','key','signature','deviceid','appid']);
const providerKey=key=>key.replace(/[_-]/g,'').toLowerCase();
function providerAuthenticationURL(raw) {
  if(typeof raw!=='string')return false;
  try {
    const u=new URL(raw),apiHost=['restapi.amap.com','flyai.open.fliggy.com','openncm.music.163.com','nos.netease.com','wanproxy-web.127.net'].includes(u.hostname.toLowerCase());
    const sensitive=key=>PROVIDER_AUTH_KEYS.has(providerKey(key))||['xamzcredential','xamzsignature','xamzsecuritytoken'].includes(providerKey(key))||apiHost&&['sign','sig','signature','key','session','sessionid','nosaccesskeyid'].includes(providerKey(key));
    if(u.username||u.password||[...u.searchParams.keys()].some(sensitive))return true;
    let fragment=u.hash.slice(1);try{fragment=decodeURIComponent(fragment);}catch{}
    return fragment.split(/[?&;]/).some(part=>part.includes('=')&&sensitive(part.split('=',1)[0]));
  } catch {return false;}
}
// Restore the original read record after the CLI formatter. Unsafe integer
// tokens stay JSON numbers in public business JSON, never rounded doubles.
// Only the current fixed read response is indexed; no account-wide cache.
function rememberProviderRecords(bytes) {
  const records=new Map(),parsed=JSON.parse(bytes.toString('utf8'),(_key,value,context)=>
    typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?JSON.rawJSON(context.source):value);
  const visit=value=>{
    if(Array.isArray(value)){for(const item of value)visit(item);return;}
    if(!object(value)||JSON.isRawJSON(value))return;
    const id=value.encryptedId??value.songId??value.playlistId??value.id;
    if(typeof id==='string'&&/^[a-f0-9]{32}$/i.test(id)) {
      const key=id.toLowerCase();check(!records.has(key),'ambiguous_provider_record');records.set(key,value);return;
    }
    for(const item of Object.values(value))visit(item);
  };
  visit(parsed.data);readContext.providerRecords=records;
}
function providerRecord(value) {
  const omitted=new Set();
  const copy=(raw,context=false)=>{
    if(providerAuthenticationURL(raw)){omitted.add('authenticated_url');return null;}
    if(JSON.isRawJSON?.(raw))return raw;
    if(Array.isArray(raw))return raw.map(item=>copy(item,context));
    if(object(raw)) {
      const result=Object.create(null);
      for(const [key,item] of Object.entries(raw)) {
        const auth=providerKey(key);
        if(auth==='xnostoken'){omitted.add('token');continue;}
        if(PROVIDER_AUTH_KEYS.has(auth)||(context&&PROVIDER_AUTH_CONTEXT_KEYS.has(auth))){omitted.add(PROVIDER_AUTH_KEYS.has(auth)?auth:'authentication_context');continue;}
        if(providerAuthenticationURL(item)){omitted.add('authenticated_url');continue;}
        result[key]=copy(item,context||PROVIDER_AUTH_CONTEXTS.has(auth));
      }
      return result;
    }
    return raw;
  };
  return {fields:copy(value),omitted_authentication_fields:[...omitted].sort()};
}
function providerBusinessStatus(raw) {
  const scalar=v=>Number.isSafeInteger(v)&&v>=0&&v<=2147483647?v:typeof v==='string'&&/^[0-9]{1,10}$/.test(v)?v:null;
  const code=scalar(raw?.code),sub=scalar(raw?.subCode);
  return {code,sub_code:sub,classification:code===200&&String(sub)==='10007'?'resource_missing':'provider_rejection'};
}
function projectItem(value,kind,rowIndex=-1) {
  check(object(value),'invalid_result_item');
  const id=readID(value.encryptedId??(kind==='song'?value.songId:value.playlistId)??value.id);
  const result={[kind+'_id']:id,name:readText(value.name,kind==='song'?800:400,kind==='song'?1:2,rowIndex)};
  const original=value.originalId;
  if((typeof original==='string'&&/^[1-9][0-9]{0,19}$/.test(original))||(Number.isSafeInteger(original)&&original>0))
    result.url='https://music.163.com/#/'+kind+'?id='+String(original);
  if(kind==='playlist'&&(value.trackCount!==undefined||value.songCount!==undefined)) {
    const count=value.trackCount??value.songCount;if(Number.isSafeInteger(count)&&count>=0)result.track_count=count;
  }
  if(kind==='playlist')result.provider_record=providerRecord(readContext?.providerRecords?.get(id)??value);
  // Internal write verification carries membership, not repeated display fields.
  // Preserve the file identity needed to recognize cloud-song re-encoding.
  if(kind==='song'&&readContext?.verification&&value.privateCloudSong!==true){
    const source=readContext?.providerRecords?.get(id)??value;
    if(typeof source.coverImgUrl==='string')result.provider_record=providerRecord({coverImgUrl:source.coverImgUrl});
    return result;
  }
  if(kind==='song'&&typeof value.visible==='boolean')result.visible=value.visible;
  if(kind==='song'){
    result.metadata=songMetadata(value,rowIndex);
    if(!readContext?.isWrite){
      if(!readContext?.verification)result.metadata.business_info=songBusinessInfo(value);
      result.provider_record=providerRecord(readContext?.verification?
        {encryptedId:id,pcId:(readContext?.providerRecords?.get(id)??value).pcId,originalId:(readContext?.providerRecords?.get(id)??value).originalId}:(readContext?.providerRecords?.get(id)??value));
      if(typeof value.privateCloudSong==='boolean')result.private_cloud_song=value.privateCloudSong;
      if(typeof value.playFlag==='boolean')result.play_flag=value.playFlag;
    }
  }
  return result;
}
// BEGIN PROJECTION_ERROR_CONTEXT: structure only, never response scalar values.
function projectionErrorShape(raw,operation,error,safe=()=>true) {
  const kind=v=>v===null?'Z':Array.isArray(v)?'A':object(v)?'O':typeof v==='string'?'S':typeof v==='number'?'N':typeof v==='boolean'?'B':'X';
  const stage={search:1,user_playlists:2,playlist_detail:3,tracks:4,cloud_songs:5}[operation];
  const shape={v:1,s:stage,r:READ_CONTRACT_CODES[error?.code]??0,t:kind(raw?.data),q:[0,0,0],n:[],a:[],h:0,o:0};
  const names=operation==='user_playlists'?['playlists','playlist','records','list']:operation==='search'?['songs','list','records']:['songs','list'];
  if(object(raw?.data))names.forEach((name,i)=>{if(Object.hasOwn(raw.data,name)){shape.q[0]++;shape.q[2]|=1<<i;if(Array.isArray(raw.data[name]))shape.q[1]++;}});
  const publicKey=k=>/^[A-Za-z_][A-Za-z0-9_]{0,31}$/.test(k)&&
    !/token|credential|secret|auth|cookie|password|account|user|profile|login|device|phone|email|address/i.test(k)&&safe(k);
  function fields(v) {
    const keys=Object.keys(v),out=[];
    if(keys.length>16)shape.o|=1;
    for(const k of keys.slice(0,16)) {
      if(publicKey(k))out.push(k+':'+kind(v[k]));else shape.h++;
    }
    return out;
  }
  const queue=[[raw,'$',0]];
  let visited=0;
  while(queue.length&&visited++<12) {
    const [value,path,depth]=queue.shift();
    if(Array.isArray(value)) {
      if(shape.a.length>=8){shape.o|=2;continue;}
      shape.a.push([path,value.length,value.length?kind(value[0]):'X',value.length&&object(value[0])?fields(value[0]):[]]);
      continue;
    }
    if(!object(value))continue;
    shape.n.push([path,fields(value)]);
    for(const k of Object.keys(value).slice(0,16)) {
      if(!publicKey(k)||!object(value[k])&&!Array.isArray(value[k]))continue;
      if(depth>=4){shape.o|=4;continue;}
      queue.push([value[k],path+'.'+k,depth+1]);
    }
  }
  if(queue.length)shape.o|=2;
  return shape;
}
function recordProjectionErrorContext(raw,operation,error) {
  if(!readContext||readContext.isWrite||!diagnostic||readContext.projectionContextRecorded||
     !['search','user_playlists','playlist_detail','tracks','cloud_songs'].includes(operation))return;
  readContext.projectionContextRecorded=true;
  const previous={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try {
    const shape=projectionErrorShape(raw,operation,error,key=>diagnostic.safe(key));
    const slots=Math.max(0,Math.min(96,120-diagnostic.count)); // Reserve 8 terminal diagnostics.
    const budget=Math.floor(Math.max(0,slots-2)*19/8);
    const compress=()=>require('node:zlib').deflateRawSync(Buffer.from(JSON.stringify(shape)),{level:6});
    let bytes=compress();
    if(bytes.length>budget) {
      shape.o|=8;
      for(const array of shape.a)array[3]=[];
      bytes=compress();
      while(bytes.length>budget&&shape.n.length>2){shape.n.pop();bytes=compress();}
      while(bytes.length>budget&&shape.n.some(node=>node[1].length)) {
        const node=[...shape.n].reverse().find(node=>node[1].length);node[1].pop();bytes=compress();
      }
    }
    const type=['X','Z','A','O','S','N','B'].indexOf(shape.t);
    diagnostic.record('bridge','ignored',{code:-97200,sub_code:100000+shape.s*10000+shape.q[0]*1000+shape.q[1]*100+type*10+(shape.o===0?1:0)});
    if(bytes.length>budget||slots<3) {diagnostic.record('bridge','ignored',{code:-97201,sub_code:0});return;}
    diagnostic.record('bridge','ignored',{code:-97201,sub_code:bytes.length});
    let accumulator=0,bits=0,index=0;
    for(const byte of bytes) {
      accumulator=accumulator*256+byte;bits+=8;
      if(bits>=19){bits-=19;const divisor=2**bits;diagnostic.record('bridge','ignored',{code:-97300-index++,sub_code:Math.floor(accumulator/divisor)});accumulator%=divisor;}
    }
    if(bits)diagnostic.record('bridge','ignored',{code:-97300-index,sub_code:accumulator*2**(19-bits)});
    bytes.fill(0);
  } catch {} // Context cannot replace the original projection failure.
  finally {Object.assign(diagnostic,previous);}
}
// END PROJECTION_ERROR_CONTEXT
// Exact authenticated CLI0.1.7 descriptor observed on 2026-10-12, not a guessed alias.
function validateCloudSongDescriptor(method) {
  check(object(method)&&method.name==='list'&&method.path==='/openapi/music/cloud/song/list/cursor/get'&&
    method.http_method==='GET'&&method.auth_required===true&&Array.isArray(method.parameters)&&
    method.parameters.length===3,'invalid_read_method');
  const expected={cursor:'string',sortType:'string',limit:'number'},seen=new Set();
  for(const p of method.parameters) {
    check(object(p)&&Object.hasOwn(expected,p.name)&&!seen.has(p.name)&&p.type===expected[p.name]&&
      p.required===false&&(p.in==='query'||p.location==='query')&&(!p.in||p.in==='query')&&
      (!p.location||p.location==='query'),'invalid_read_parameter');
    seen.add(p.name);
  }
}
function validCloudCursor(value) {
  return typeof value==='string'&&Buffer.byteLength(value)<=1024&&value.length>0&&!value.startsWith('-')&&!/[\x00-\x1f\x7f]/.test(value);
}
function projectCloudSongs(raw) {
  check(object(raw)&&Number.isSafeInteger(raw.code)&&[0,200].includes(raw.code)&&raw.success!==false&&object(raw.data),'invalid_read_reply');
  const data=raw.data,fields=['songs','list','records'].filter(k=>Object.hasOwn(data,k));
  check(fields.length===1&&Array.isArray(data[fields[0]])&&data[fields[0]].length<=(readContext?.cloudLimit??50),'result_count_limit');
  const items=data[fields[0]].map((row,index)=>{
    const out=projectItem(row,'song',index);
    if(typeof row.privateCloudSong==='boolean')out.private_cloud_song=row.privateCloudSong;
    if(typeof row.playFlag==='boolean')out.play_flag=row.playFlag;
    return out;
  });
  check(new Set(items.map(x=>x.song_id)).size===items.length,'duplicate_result_id');
  let cursor=null;
  for(const k of ['cursor','nextCursor'])if(Object.hasOwn(data,k)&&data[k]!==null&&data[k]!=='') {
    check(validCloudCursor(data[k])&&(cursor===null||cursor===data[k]),'inconsistent_pagination');cursor=data[k];
  }
  let hasMore=null;
  if(Object.hasOwn(data,'hasMore')) {check(typeof data.hasMore==='boolean','invalid_has_more');hasMore=data.hasMore;}
  if(hasMore===false)cursor=null;
  if(hasMore===true)check(cursor!==null&&items.length>0,'inconsistent_pagination');
  if(cursor!==null)check(cursor!==(readContext?.arguments?.cursor??null),'inconsistent_pagination');
  let total=null;
  for(const k of ['recordCount','total','songCount'])if(Object.hasOwn(data,k)) {
    check(Number.isSafeInteger(data[k])&&data[k]>=items.length&&
      (total===null||total===data[k]),'invalid_result_total');total=data[k];
  }
  const value={songs:items,complete:hasMore===false,cloud_page:{limit:readContext?.cloudLimit??50,total,has_more:hasMore,next_cursor:cursor}};
  check(secretFreeProjection(value),'invalid_read_reply');return value;
}

function validateLibraryArguments(operation,args) {
  const spec=LIBRARY_READ_SPECS[operation];
  check(object(args)&&Object.keys(args).every(k=>spec.fields.includes(k))&&spec.required.every(k=>Object.hasOwn(args,k)),'invalid_read_arguments');
  for(const [key,value] of Object.entries(args)) {
    check(typeof value==='string','invalid_read_arguments');
    if(['albumId','artistId','songId'].includes(key))readID(value);
    else if(key==='keyword'){readText(value,400);check([...value].length<=100&&!value.startsWith('-'),'invalid_keyword');}
    else if(['descFlag','qualityFlag'].includes(key))check(['true','false'].includes(value),'invalid_read_arguments');
    else {
      check(/^(0|[1-9][0-9]{0,15})$/.test(value)&&Number.isSafeInteger(Number(value)),'invalid_read_arguments');
      if(key==='limit')check(Number(value)>=1&&Number(value)<=(operation==='playlist_collected'?500:100),'invalid_read_arguments');
      if(key==='offset')check(Number.isSafeInteger(Number(value)),'invalid_read_arguments');
    }
  }
  if(operation==='artist_songs')check(Number(args.startTime)<=Number(args.endTime),'invalid_read_arguments');
}
function projectLibraryRead(operation) {
  check(typeof readContext.libraryProviderJSON==='string'&&object(readContext.libraryParameters),'missing_typed_output');
  const raw=JSON.parse(readContext.libraryProviderJSON,(_key,value,context)=>
    typeof value==='number'&&Number.isInteger(value)&&!Number.isSafeInteger(value)?JSON.rawJSON(context.source):value);
  if(!object(raw)||![0,200].includes(raw.code)||raw.success===false||
    raw.subCode!==undefined&&raw.subCode!==null&&![0,200,'0','200'].includes(raw.subCode)) {
    readFailure('provider_rejected',{reason:'provider_rejected',stage:'provider_response',httpStatus:readContext.activeHTTPStatus});
    throw fault('invalid_read_reply');
  }
  check(Object.hasOwn(raw,'data'),'invalid_read_reply');
  return {operation,parameters:readContext.libraryParameters,provider_record:providerRecord(raw),coverage:'single_provider_response'};
}

function projectRead(raw,operation,offset=0) {
  if(!readContext?.isWrite&&object(raw)&&raw.code===200&&String(raw.subCode)==='10007'&&raw.data===null){
    readFailure('provider_rejected',{reason:'provider_resource_missing',stage:'provider_response',httpStatus:readContext?.activeHTTPStatus,providerStatus:providerBusinessStatus(raw)});
    throw fault('provider_resource_missing');
  }
  try {return projectReadValue(raw,operation,offset);}
  catch(error) {recordProjectionErrorContext(raw,operation,error);readFailure('contract_rejected',{reason:'result_schema_invalid',stage:'projection',localCode:READ_CONTRACT_CODES[error?.code],httpStatus:readContext?.activeHTTPStatus});throw error;}
}

function projectReadValue(raw,operation,offset=0) {
  if(operation==='cloud_songs')return projectCloudSongs(raw);
  check(object(raw)&&Number.isSafeInteger(raw.code)&&[0,200].includes(raw.code)&&raw.success!==false&&Object.hasOwn(raw,'data'),'invalid_read_reply');
  const data=raw.data;
  if(operation==='playlist_detail') {
    const playlist=projectItem(object(data)&&object(data.playlist)?data.playlist:data,'playlist');
    check(playlist.playlist_id===readContext.arguments.playlist_id,'playlist_identity_mismatch');return playlist;
  }
  if(operation==='tracks'&&trackEmptyObservation(raw,{offset})&&readContext.lastTrackEmpty)
    return {items:[],total:offset,hasMore:false,complete:true,terminalObservation:readContext.lastTrackEmpty};
  const kind=operation==='user_playlists'?'playlist':'song';
  let rows=data;
  if(object(data)) {
    const names=kind==='playlist'?['playlists','playlist','records','list']:operation==='search'?['songs','list','records']:['songs','list'];
    const found=names.filter(name=>Object.hasOwn(data,name));check(found.length===1,'ambiguous_result_array');rows=data[found[0]];
  }
  check(Array.isArray(rows)&&rows.length<=(operation==='tracks'?100:operation==='user_playlists'?50:20),'result_count_limit');
  const items=rows.map((row,index)=>projectItem(row,kind,index));
  check(new Set(items.map(row=>row[kind+'_id'])).size===items.length,'duplicate_result_id');
  let total=null,hasMore=null;
  if(object(data)) {
    for(const name of ['recordCount','total','songCount'])if(Object.hasOwn(data,name)) {
      check(Number.isSafeInteger(data[name])&&data[name]>=offset+items.length,'invalid_result_total');
      check(total===null||total===data[name],'inconsistent_result_total');total=data[name];
    }
    if(Object.hasOwn(data,'hasMore')){check(typeof data.hasMore==='boolean','invalid_has_more');hasMore=data.hasMore;}
    check(!(hasMore===true&&total===offset+items.length),'inconsistent_pagination');
    check(!(hasMore===false&&total!==null&&total!==offset+items.length),'inconsistent_pagination');
  }
  return {items,total,hasMore,complete:hasMore===false||total===offset+items.length};
}
// BEGIN BOUNDED_PAGINATION: the production command loop calls this exact helper.
async function collectPlaylistMetadata(invoke) {
  const before=await invoke('playlist_detail'),after=await invoke('playlist_detail');
  const description=row=>{const fields=row.provider_record?.fields??{};
    const values=['describe','description','desc'].filter(k=>Object.hasOwn(fields,k)).map(k=>fields[k]===null?'':fields[k]);
    return values.length&&values.every(v=>typeof v==='string'&&v===values[0])?values[0]:null;};
  const witness=row=>({playlist_id:row.playlist_id,name:row.name,description:description(row)});
  check(JSON.stringify(witness(before))===JSON.stringify(witness(after)),'playlist_metadata_changed');
  return after;
}
async function collectMusicPages(fetchPage,{kind,pageSize,maxPages=Infinity,maxItems=Infinity,maxBytes=98304,expectedTotal=null,withinBudget=()=>true,startOffset=0}) {
  async function sweep() {
    const items=[],seen=new Set(),observations=[];let total=expectedTotal,pages=0,itemBytes=2;
    const done=(state,complete=false)=>({items,total,complete,pagination:{state,pages,items:items.length,total,
      ...(observations.length?{terminal_observations:observations}:{}),offset:startOffset,next_offset:state==='budget_exhausted'&&items.length>0&&(total===null||startOffset+items.length<total)?startOffset+items.length:null}});
    while(pages<maxPages&&withinBudget()) {
      const page=await fetchPage(startOffset+items.length);pages++;
      if(page.terminalObservation)observations.push(page.terminalObservation);
      if(page.total!==null) {
        if(total!==null&&total!==page.total)return done('drift');
        total=page.total;
      }
      if(page.items.length>pageSize)return done('drift');
      if(total!==null&&startOffset+items.length+page.items.length>total)return done('drift');
      if(page.items.some(row=>seen.has(row[kind+'_id'])))return done('drift');
      if(new Set(page.items.map(row=>row[kind+'_id'])).size!==page.items.length)return done('drift');
      // Retain the existing result budget. Admit whole items up to it, then
      // return an explicit offset for the unreturned suffix of this same page.
      // A page which exceeds the budget must never erase its fitting prefix.
      for(const row of page.items) {
        const bytes=Buffer.byteLength(JSON.stringify(row))+(items.length?1:0);
        if(items.length>=maxItems||itemBytes+bytes>maxBytes)return done('budget_exhausted');
        seen.add(row[kind+'_id']);items.push(row);itemBytes+=bytes;
      }
      const reached=total!==null&&startOffset+items.length===total;
      if(page.hasMore===true&&reached||page.hasMore===false&&total!==null&&!reached)return done('drift');
      if(reached||page.hasMore===false)return done('complete',true);
      if(page.items.length===0)return done('unproven_end');
      if(page.hasMore===null&&total===null)return done('unproven_end');
    }
    return done('budget_exhausted');
  }
  const first=await sweep();
  if(!first.complete)return first;
  // Reaching the end from a continuation offset is not complete coverage of
  // the whole playlist. It can never satisfy the owner's write preflight.
  if(startOffset>0)return {...first,complete:false,pagination:{...first.pagination,state:'continuation_end'}};
  const second=await sweep();
  const observations=[...(first.pagination.terminal_observations??[]),...(second.pagination.terminal_observations??[])];
  const terminal=observations.length?{terminal_observations:observations}:{};
  const identity=items=>kind==='song'?items.map(row=>[row.song_id,row.name]):items.map(row=>[row.playlist_id,row.name]).sort((a,b)=>a[0].localeCompare(b[0]));
  if(!second.complete||first.total!==second.total||JSON.stringify(identity(first.items))!==JSON.stringify(identity(second.items)))
    return {...first,complete:false,pagination:{...first.pagination,state:second.pagination.state==='budget_exhausted'?'budget_exhausted':'drift',pages:first.pagination.pages+second.pagination.pages,...terminal}};
  // Unchanged write-facing meaning: two identical complete sweeps from zero.
  return {...first,complete:true,pagination:{...first.pagination,pages:first.pagination.pages+second.pagination.pages,state:'stable_observed',...terminal}};
}
// END BOUNDED_PAGINATION
function projectWrite(raw) {
  check(object(raw)&&Number.isSafeInteger(raw.code)&&[0,200].includes(raw.code)&&raw.success!==false,'invalid_write_reply');
  let id=readContext.arguments.playlist_id||null;
  if(readContext.operation==='playlist_create') {
    const data=object(raw.data)&&object(raw.data.playlist)?raw.data.playlist:raw.data;
    check(object(data),'invalid_created_playlist');
    id=readID(data.encryptedId??data.playlistId??data.id);
    if(data.name!==undefined)check(data.name===readContext.arguments.name,'created_name_mismatch');
  }
  if(readContext.operation==='playlist_cover')return coverResult(readContext.cover.providerRejected?'provider_rejected':'submitted');
  const result={state:'submitted',playlist_id:id,...(readContext.lastProviderResult?{provider_result:readContext.lastProviderResult}:{})};
  check(secretFreeProjection(result),'private_write_projection');return result;
}
function installReadCommandBoundary(commander) {
  const original=commander.Command.prototype.parseAsync;
  commander.Command.prototype.parseAsync=async function(argv,...rest) {
    const session=inspectSession();
    if(!session.present){readFailure(readContext.refreshRejected?'refresh_rejected':'login_required');return this;}
    if(readContext.failure)return this;
    check(readContext.manifests,'missing_dynamic_manifest');
    const invoke=async(stage,offset=0,cloudLimit=50)=>{
      const mapping=readContext.manifests[stage];
      check(mapping,'missing_fixed_operation_mapping');
      const values=batchOperations.has(stage)?batchValues(stage,readContext.arguments):metadataOperations.has(stage)?metadataValues(stage,readContext.arguments):stage==='playlist_cover'?{playlistId:readContext.arguments.playlist_id,picIds:readContext.arguments.image_path}:stage==='playlist_create'?{playlistName:readContext.arguments.name}:
        stage==='playlist_append'?{playlistId:readContext.arguments.playlist_id,songIdList:readContext.arguments.song_id}:libraryOperations.has(stage)?{...readContext.arguments}:stage==='search'?{keyword:readContext.arguments.keyword,limit:'20'}:
        stage==='cloud_songs'?{limit:String(cloudLimit),...(readContext.arguments.cursor?{cursor:readContext.arguments.cursor}:{})}:
        stage==='user_playlists'?{limit:'50',offset:String(offset)}:
        stage==='tracks'?{playlistId:readContext.arguments.playlist_id,limit:'100',offset:String(offset)}:{playlistId:readContext.arguments.playlist_id};
      if(stage==='search') {
        check(offset===0||mapping.names.has('offset'),'search_continuation_unsupported');
        if(mapping.names.has('offset'))values.offset=String(offset);
      }
      const args=[process.execPath,argv[1],mapping.group,mapping.name];
      for(const [name,value]of Object.entries(values)) { if(metadataOperations.has(stage)||batchOperations.has(stage))args.push('--'+name+'='+value);else args.push('--'+name,value); }
      args.push('--output','json','--userInput',metadataOperations.has(stage)?'用户要求更新选定歌单的元数据':stage==='playlist_create'?'用户要求创建歌单：'+readContext.arguments.name:stage==='playlist_cover'?'用户要求更新选定歌单的封面':stage==='playlist_append'?'用户要求向选定歌单添加选定歌曲':libraryOperations.has(stage)?'只读查询网易云音乐公开目录或已授权收藏':stage==='search'?'搜索歌曲':stage==='cloud_songs'?'只读查看云盘歌曲':stage==='user_playlists'?'查看我的歌单':'查看歌单');
      readContext.activePath=mapping.path;readContext.activeMethod=mapping.httpMethod;readContext.cloudLimit=cloudLimit;readContext.expectedBusiness=Object.fromEntries(
        Object.entries(values).map(([name,value])=>[name,mapping.arrayFields.has(name)?batchOperations.has(stage)?strictJSON(Buffer.from(value)):[value]:value]));readContext.stage=stage;readContext.providerRecords=null;readContext.lastTrackEmpty=null;readContext.lastProviderResult=null;readContext.captured=null;readContext.outputCount=0;readContext.activeHTTPStatus=null;readContext.sizeReported=false;
      // Adapt only a declared single-song array through the public Option parser.
      let option,previousParser;
      if(['playlist_append','playlist_add_songs','playlist_remove_songs'].includes(stage)&&mapping.httpMethod==='POST'&&mapping.arrayFields.has('songIdList')&&mapping.path===READ_SPECS[stage].path) {
        const groups=this.commands.filter(command=>command.name()===mapping.group);
        check(groups.length===1,'missing_fixed_operation_mapping');
        const commands=groups[0].commands.filter(command=>command.name()===mapping.name);
        check(commands.length===1,'missing_fixed_operation_mapping');
        const options=commands[0].options.filter(value=>value.long==='--songIdList');
        check(options.length===1&&options[0].required&&!options[0].optional&&!options[0].variadic&&options[0].parseArg===undefined,'invalid_write_parameter_shape');
        option=options[0];previousParser=option.parseArg;
        option.argParser(value=>{const expected=stage==='playlist_append'?readContext.arguments.song_id:readContext.arguments.song_ids;check(value===expected,'read_business_mismatch');return stage==='playlist_append'?[value]:strictJSON(Buffer.from(value));});
      }
      try {await original.call(this,args,...rest);}
      finally {if(option)option.argParser(previousParser);}
      if(readContext.failure||readContext.outputCount!==1||!readContext.captured) {
        readFailure('contract_rejected',{reason:'cli_output_missing',stage:'cli_output',localCode:READ_CONTRACT_CODES.missing_typed_output,httpStatus:readContext.activeHTTPStatus});
        throw fault('missing_typed_output');
      }
      const result=readContext.isWrite?projectWrite(readContext.captured):libraryOperations.has(stage)?projectLibraryRead(stage):projectRead(readContext.captured,stage,offset);
      readContext.captured=null;readContext.activePath=null;
      return result;
    };
    const withinBudget=()=>performance.now()<readContext.pageDeadline;
    const verificationBudget=readContext.verification?{maxBytes:Infinity}:{};
    if(readContext.operation==='user_playlists')readContext.results.user_playlists=await collectMusicPages(offset=>invoke('user_playlists',offset),
      {kind:'playlist',pageSize:50,...verificationBudget,withinBudget,startOffset:Number(readContext.arguments.offset||'0')});
    else if(readContext.operation==='playlist_detail'&&readContext.metadataOnly) {
      readContext.results.playlist_detail=await collectPlaylistMetadata(invoke);
      readContext.results.metadata_verified=true;
    } else if(readContext.operation==='playlist_detail') {
      const before=await invoke('playlist_detail');readContext.results.playlist_detail=before;
      readContext.validatedPlaylist=true;readContext.validatedPlaylistTrackCount=before.track_count??null;
      readContext.results.tracks=await collectMusicPages(offset=>invoke('tracks',offset),
        {kind:'song',pageSize:100,...verificationBudget,expectedTotal:before.track_count??null,withinBudget,startOffset:Number(readContext.arguments.offset||'0')});
      if(readContext.results.tracks.complete) {
        if(withinBudget()) {
          const after=await invoke('playlist_detail');
          if(before.playlist_id!==after.playlist_id||before.name!==after.name||before.track_count!==after.track_count) {
            readContext.results.tracks.complete=false;readContext.results.tracks.pagination.state='drift';
          }
        } else {readContext.results.tracks.complete=false;readContext.results.tracks.pagination.state='budget_exhausted';}
      }
    } else if(readContext.operation==='cloud_songs') {
      // Ask the provider for a smaller complete page at the same cursor when the
      // private transport cannot carry it. Never slice a cursor-based cloud page:
      // its returned cursor must account for every returned song.
      let limit=Number(readContext.arguments.limit||'50'),result=await invoke('cloud_songs',0,limit);
      const fits=payload=>{
        const stored={};for(const name of persistent)if(files.has(name))stored[name]=files.get(name).toString('base64');
        const credential=Buffer.from(JSON.stringify({schema:1,storage:'official',files:stored})).toString('base64');
        const result={state:'authorized_read',session:'refreshed',payload};
        const frame={schema:1,call_id:'00000000-0000-4000-8000-000000000001',event:'read_complete',operation:'cloud_songs',result,credential};
        return Buffer.byteLength(JSON.stringify(frame)+'\n')<=MAX*2&&Buffer.byteLength(JSON.stringify(result).replace(/\//g,'\\/'))<=MAX*2-2048;
      };
      while(!fits(result)&&limit>1&&withinBudget()) {
        limit=Math.max(1,Math.floor(limit/2));result=await invoke('cloud_songs',0,limit);
      }
      check(fits(result),'response_limit');readContext.results.cloud_songs=result;
    } else readContext.results[readContext.operation]=await invoke(readContext.operation,readContext.operation==='search'?Number(readContext.arguments.offset||'0'):0);
    return this;
  };
}
// Search-only scalar telemetry, two base-1,000,000 digits, never output content.
// Restoring attribution keeps ancillary measurements out of terminal failures.
function recordSearchOutputBytes(bytes) {
  if(!readContext||readContext.isWrite||readContext.stage!=='search'||readContext.sizeReported||!diagnostic)return;
  readContext.sizeReported=true;
  const previous={phase:diagnostic.phase,last:diagnostic.last,lastValues:diagnostic.lastValues};
  try {
    diagnostic.record('bridge','ignored',{code:-97400,sub_code:bytes%1000000});
    diagnostic.record('bridge','ignored',{code:-97401,sub_code:Math.floor(bytes/1000000)});
  } catch {} finally {Object.assign(diagnostic,previous);}
}
// Preserve string contents and primitive-token whitespace: [1 2] must not
// become [12]. Scan the complete bounded input, never a cropped prefix.
function normalizedReadJSON(value,rawBytes) {
  const limit=(bytes,budget)=>Object.assign(fault('read_cli_output_limit'),{outputBytes:bytes,outputLimit:budget});
  if(rawBytes>MAX_READ_CLI_FORMATTED)throw limit(rawBytes,MAX_READ_CLI_FORMATTED);
  let quoted=false,escaped=false,gap=false,previous='',chunk='';const pieces=[];
  const primitive=char=>/[A-Za-z0-9+\-.]/.test(char);
  const append=char=>{
    chunk+=char;if(chunk.length>=4096){pieces.push(chunk);chunk='';}
  };
  for(const char of value) {
    if(!quoted&&/[ \t\r\n]/.test(char)){gap=true;continue;}
    if(gap&&primitive(previous)&&primitive(char))append(' ');
    gap=false;append(char);
    if(quoted){if(escaped)escaped=false;else if(char.codePointAt(0)===92)escaped=true;else if(char==='"')quoted=false;}
    else if(char==='"')quoted=true;
    previous=char;
  }
  pieces.push(chunk);return pieces.join('');
}
function captureOutput(value) {
  if(typeof value!=='string')return;
  // The pinned image preprocessor emits progress strings. Only its final
  // object is typed output; absence/duplicates still fail closed below.
  if(readContext?.operation==='playlist_cover'&&!value.trimStart().startsWith('{'))return;
  const boundedRead=readContext?.stage&&(!readContext.isWrite||readContext.operation==='playlist_cover'),outputBytes=Buffer.byteLength(value);
  if(boundedRead)recordSearchOutputBytes(outputBytes);
  if(!boundedRead&&outputBytes>65536)return;
  try {
    const item=strictJSON(Buffer.from(boundedRead?normalizedReadJSON(value,outputBytes):value));
    if(object(item)&&item.success===false&&!diagnostic?.failed)diagnostic?.record(diagnostic.phase,'unconfirmed');
    if(readContext && readContext.stage) {
      readContext.outputCount++;
      check(readContext.outputCount===1,'duplicate_cli_output');
      readContext.captured=item;return;
    }
    if (item && typeof item==='object' && typeof item.success==='boolean') {
      publicResult={success:item.success,status:['success','expired','waiting','confirming'].includes(item.status)?item.status:null};
    }
  } catch(error) {
    if(readContext?.stage)readFailure('contract_rejected',error?.code==='read_cli_output_limit'?
      {reason:'cli_output_too_large',stage:'cli_output',localCode:READ_CONTRACT_CODES.read_cli_output_limit,httpStatus:readContext.activeHTTPStatus,outputBytes:error.outputBytes,outputLimit:error.outputLimit}:
      {reason:'cli_output_invalid',stage:'cli_output',localCode:READ_CONTRACT_CODES[error?.code],httpStatus:readContext.activeHTTPStatus});
  }
}
function installOutputBoundary(callID) {
  for (const name of ['log','info','warn','error','debug']) console[name]=(...values)=>{
    if(values.length===1)captureOutput(values[0]);
    // Only recognize the official local signing-error prefix. Never forward text.
    if(values.some(value=>typeof value==='string'&&value.includes('RSA SHA256 签名失败:')))diagnostic?.record(diagnostic.phase,'signing_failed');
  };
  process.stdout.write=(chunk,_encoding,done)=>{captureOutput(Buffer.isBuffer(chunk)?chunk.toString('utf8'):chunk);if(typeof done==='function')done();return true;};
  process.stderr.write=(_chunk,_encoding,done)=>{if(typeof done==='function')done();return true;};
  // Prevent 0.1.7 from silently selecting its detached/background login branch,
  // which carries a login key in a child environment. No child process permission.
  Object.defineProperty(process.stdin,'isTTY',{value:true});
  Object.defineProperty(process.stdout,'isTTY',{value:true});
  const load=Module._load;
  Module._load=function(name,parent,isMain){
    const result=load.apply(this,arguments);
    if(name==='commander'&&readContext&&!readContext.commandBoundary){readContext.commandBoundary=true;installReadCommandBoundary(result);}
    if(name==='qrcode-terminal') return {...result,generate(url,_options,callback){
      const reason=FiniteDiagnostics.qrURLReason(url);
      if(reason)diagnostic?.record('qr_payload','invalid_response',{reason_code:reason});
      check(reason===null,'invalid_login_url');
      diagnostic?.record('qr_payload','succeeded');
      diagnostic?.record('qr_delivery','started');
      try {frame({schema:1,call_id:callID,event:'login_qr',url});}
      catch(error){diagnostic?.record('qr_delivery','invalid_response',{reason_code:'qr_frame_write'});throw error;}
      if(typeof callback==='function')callback('');
      return '';
    }};
    return result;
  };
}
function finish(request) {
  if(finished)return;
  let state='provider_unconfirmed';
  if(request.operation==='prepare' && exitCode===0 && files.has('.config/ncm-cli/credentials.enc.json'))state='saved_unverified';
  else if(request.operation==='status')state=publicResult?.success===true?'session_present_unverified':publicResult?.success===false?'login_required':'provider_unconfirmed';
  else if(request.operation==='login')state=publicResult?.success===true&&publicResult.status==='success'?'session_present_unverified':publicResult?.status==='expired'?'login_expired':'provider_unconfirmed';
  let readResult;
  if(readContext) {
    let session;try{session=inspectSession();}catch{readFailure('contract_rejected',{reason:'session_state_invalid',stage:'session'});session={present:false};}
    const results=readContext.results;
    let payload=null;
    if(!readContext.failure && exitCode===0) {
      if(readContext.operation==='search'&&results.search) {
        const page=results.search,offset=Number(readContext.arguments.offset||'0'),supported=readContext.manifests.search.names.has('offset');
        const next=offset+page.items.length,more=page.hasMore===true||page.total!==null&&next<page.total;
        payload={songs:page.items,complete:offset===0&&page.complete,search_page:{offset,limit:20,total:page.total,
          continuation_supported:supported,next_offset:supported&&more&&page.items.length>0?next:null}};
      }
      if(libraryOperations.has(readContext.operation)&&results[readContext.operation])payload={library:results[readContext.operation],complete:false};
      if(readContext.operation==='cloud_songs'&&results.cloud_songs)payload=results.cloud_songs;
      if(readContext.operation==='user_playlists'&&results.user_playlists)payload={playlists:results.user_playlists.items,complete:results.user_playlists.complete,pagination:results.user_playlists.pagination};
      if(readContext.operation==='playlist_detail'&&results.playlist_detail&&results.metadata_verified===true)
        payload={playlist:results.playlist_detail,complete:false,metadata_verified:true};
      if(readContext.operation==='playlist_detail'&&results.playlist_detail&&results.tracks) {
        const count=results.playlist_detail.track_count;
        if(results.tracks.total!==null&&count!==undefined&&results.tracks.total!==count)readFailure('contract_rejected',{reason:'result_schema_invalid',stage:'projection',localCode:READ_CONTRACT_CODES.inconsistent_result_total,httpStatus:readContext.activeHTTPStatus});
        if(count===undefined&&results.tracks.complete)results.tracks.pagination.state='unproven_end';
        payload={playlist:results.playlist_detail,songs:results.tracks.items,
          complete:results.tracks.complete&&count!==undefined&&count===results.tracks.items.length,pagination:results.tracks.pagination};
      }
    }
    if(payload&&!secretFreeProjection(payload))readFailure('contract_rejected',{reason:'result_schema_invalid',stage:'projection',localCode:READ_CONTRACT_CODES.invalid_read_reply,httpStatus:readContext.activeHTTPStatus});
    const state=payload&&session.present&&!readContext.failure?'authorized_read':readContext.failure||'contract_rejected';
    readResult={state,session:readContext.refreshRejected?'rejected':session.present?
      (readContext.refreshAttempted?'refreshed':'present'):state==='login_required'?'missing':'unconfirmed',payload:state==='authorized_read'?payload:null};
    if(state!=='authorized_read'&&!readContext.isWrite)readResult.failure=publicReadFailure(state,request.call_id);
    if(readContext.lastProviderIssue)readResult.provider_result=readContext.lastProviderIssue;
  }
  const stored={};
  for(const name of persistent)if(files.has(name))stored[name]=files.get(name).toString('base64');
  const envelope={schema:1,storage:'official',files:stored};
  const encoded=Buffer.from(JSON.stringify(envelope));check(encoded.length<=MAX,'state_limit');
  try {
    for(const [name,value] of Object.entries(stored))validateFile(name,Buffer.from(value,'base64'));
    check(Object.hasOwn(stored,'.netease_mcp_device.json')&&Object.hasOwn(stored,'.config/ncm-cli/credentials.enc.json'),'incomplete_state');
    if(!diagnostic?.failed)diagnostic?.record('complete',readResult?
      (readResult.state==='authorized_read'?'succeeded':readResult.state==='login_required'?'login_required':'unconfirmed'):
      state==='provider_unconfirmed'?'unconfirmed':state==='login_expired'?'expired':state==='login_required'?'login_required':'succeeded');
    if(readContext?.operation==='playlist_cover') {
      const result=!readContext.failure&&readContext.results[request.operation]?readContext.results[request.operation]:
        coverResult(readContext.effectAttempted?(readContext.failure==='provider_rejected'?'provider_rejected':'outcome_unknown'):'not_submitted');
      // Carry the complete safe reply through bounded private frames. The frame
      // boundary is independent of the combined provider/receipt result size.
      const bytes=Buffer.from(JSON.stringify(result)),digest=crypto.createHash('sha256').update(bytes).digest('hex');
      const parts=Math.ceil(bytes.length/65536);
      try {
        for(let part=0;part<parts;part++)frame({schema:1,call_id:request.call_id,event:'cover_result_part',
          part,parts,sha256:digest,payload:bytes.subarray(part*65536,(part+1)*65536).toString('base64')});
        frame({schema:1,call_id:request.call_id,event:'cover_complete',operation:request.operation,
          result_sha256:digest,credential:encoded.toString('base64')});
      } finally {bytes.fill(0);}
    }
    else if(readContext?.isWrite)frame({schema:1,call_id:request.call_id,event:'write_complete',operation:request.operation,
      result:!readContext.failure&&readContext.results[request.operation] ? readContext.results[request.operation] :
        {state:readContext.effectAttempted?'outcome_unknown':'not_submitted',playlist_id:null,...(readContext.lastProviderResult?{provider_result:readContext.lastProviderResult}:{})},credential:encoded.toString('base64')});
    else if(readContext) {
      const reply={schema:1,call_id:request.call_id,event:'read_complete',operation:request.operation,
        result:readResult,credential:encoded.toString('base64')};
      // Credential size and private framing cannot truncate business coverage.
      if(Buffer.byteLength(JSON.stringify(reply)+'\n')>MAX*2) {
        const bytes=Buffer.from(JSON.stringify(readResult)),digest=crypto.createHash('sha256').update(bytes).digest('hex');
        const parts=Math.ceil(bytes.length/65536);
        try {
          for(let part=0;part<parts;part++)frame({schema:1,call_id:request.call_id,event:'read_result_part',part,parts,
            sha256:digest,payload:bytes.subarray(part*65536,(part+1)*65536).toString('base64')});
          frame({schema:1,call_id:request.call_id,event:'read_complete',operation:request.operation,
            result_sha256:digest,credential:encoded.toString('base64')});
        } finally {bytes.fill(0);}
      } else frame(reply);
    }
    else frame({schema:1,call_id:request.call_id,event:'complete',state,credential:encoded.toString('base64')});
    finished=true;
  } finally { encoded.fill(0); }
  readContext?.cover?.image?.fill(0);
  encoded.fill(0);for(const bytes of files.values())bytes.fill(0);files.clear();privatePatterns.clear();privatePatternBytes=0;
}
try {
  const request=readRequest();
  const isWrite=writeOperations.has(request.operation);
  const isRead=readOperations.has(request.operation)||isWrite;
  const auditKeys=Object.hasOwn(request,'business_audit')?['business_audit']:[];
  check((auditKeys.length===0||isRead&&request.business_audit===true)&&keys(request,(isRead?['schema','operation','call_id','credential','network_allowed','arguments']:['schema','operation','call_id','credential','network_allowed']).concat(auditKeys)) && request.schema===1 && (Object.hasOwn(operationArgs,request.operation)||isRead) && uuid(request.call_id) && typeof request.network_allowed==='boolean' && (request.operation!=='prepare'||request.network_allowed===false),'invalid_request');
   const diagnosticSafe=value=>secretFreeProjection(value)&&(!isWrite||Object.values(request.arguments||{}).every(privateValue=>
     typeof privateValue!=='string'||![privateValue,Buffer.from(privateValue).toString('base64'),encodeURIComponent(privateValue)].some(text=>typeof value==='string'&&value.includes(text))));
   diagnostic=new FiniteDiagnostics(request.call_id,frame,diagnosticSafe,undefined,refreshDiagnosticSecrets);
   if(request.business_audit)businessAudit={callID:request.call_id,spanID:crypto.randomUUID()};
  diagnostic?.record('initialize','started');
  if(isRead) {
    const pageOffset=Object.hasOwn(request.arguments,'offset');
    const verification=Object.hasOwn(request.arguments,'verification');
    if(verification) {
      check(['user_playlists','playlist_detail'].includes(request.operation)&&request.arguments.verification==='true'&&!pageOffset,'invalid_read_arguments');
      delete request.arguments.verification;
    }
    const metadataOnly=Object.hasOwn(request.arguments,'metadata_only');
    if(metadataOnly){
      check(verification&&request.operation==='playlist_detail'&&request.arguments.metadata_only==='true'&&!pageOffset,'invalid_read_arguments');
      delete request.arguments.metadata_only;
    }
    if(libraryOperations.has(request.operation))validateLibraryArguments(request.operation,request.arguments);
    check(keys(request.arguments,libraryOperations.has(request.operation)?Object.keys(request.arguments):batchOperations.has(request.operation)?['playlist_id',request.operation==='playlist_update_tags'?'tags':'song_ids']:metadataOperations.has(request.operation)?['playlist_id','value']:request.operation==='playlist_cover'?['playlist_id','image_path','image_sha256','image_bytes']:request.operation==='playlist_create'?['name']:request.operation==='playlist_append'?['playlist_id','song_id']:request.operation==='search'?(pageOffset?['keyword','offset']:['keyword']):request.operation==='cloud_songs'?['cursor','limit'].filter(k=>Object.hasOwn(request.arguments,k)):request.operation==='playlist_detail'?(pageOffset?['playlist_id','offset']:['playlist_id']):request.operation==='user_playlists'&&pageOffset?['offset']:[]),'invalid_read_arguments');
    if(['user_playlists','playlist_detail'].includes(request.operation)&&pageOffset)check(typeof request.arguments.offset==='string'&&/^(0|[1-9][0-9]*)$/.test(request.arguments.offset)&&Number.isSafeInteger(Number(request.arguments.offset)),'invalid_read_offset');
    if(request.operation==='playlist_create') {readText(request.arguments.name,400);check([...request.arguments.name].length<=100&&request.arguments.name===request.arguments.name.trim()&&!request.arguments.name.startsWith('-'),'invalid_playlist_name');}
    if(request.operation==='playlist_cover') {
      request.arguments.playlist_id=readID(request.arguments.playlist_id);
      check(typeof request.arguments.image_path==='string'&&path.isAbsolute(request.arguments.image_path)&&
        !request.arguments.image_path.includes(',')&&!request.arguments.image_path.includes('\0')&&/\.(jpg|png)$/.test(request.arguments.image_path)&&
        /^[a-f0-9]{64}$/.test(request.arguments.image_sha256)&&/^[1-9][0-9]*$/.test(request.arguments.image_bytes),'invalid_cover_image');
      const image=actualRead(request.arguments.image_path);
      check(image.length===Number(request.arguments.image_bytes)&&crypto.createHash('sha256').update(image).digest('hex')===request.arguments.image_sha256,'invalid_cover_image');
      request.coverImage=image;
    }
    if(batchOperations.has(request.operation)) {
      request.arguments.playlist_id=readID(request.arguments.playlist_id);
      const tags=request.operation==='playlist_update_tags',field=tags?'tags':'song_ids';
      check(typeof request.arguments[field]==='string','invalid_read_arguments');
      const items=strictJSON(Buffer.from(request.arguments[field]));
      check(Array.isArray(items)&&items.length>0&&items.every(x=>typeof x==='string')&&new Set(items.map(x=>tags?x:x.toLowerCase())).size===items.length,'invalid_read_arguments');
      if(tags)check(items.length<=3&&items.every(x=>x.length>0&&!/[\x00-\x1f\x7f]/.test(x)),'invalid_read_arguments');
      else {items.forEach(readID);if(request.operation==='playlist_remove_songs')check(items.length<=500,'invalid_read_arguments');}
    }
    if(metadataOperations.has(request.operation)) {
      request.arguments.playlist_id=readID(request.arguments.playlist_id);
      const value=request.arguments.value;
      check(typeof value==='string','invalid_playlist_metadata');
      if(request.operation==='playlist_update_name')check(value.length>0&&[...value].length<=100&&Buffer.byteLength(value)<=400&&value===value.trim()&&!value.startsWith('-')&&!/[\x00-\x1f\x7f]/.test(value),'invalid_playlist_name');
      else check([...value].length<=1000&&Buffer.byteLength(value)<=4000&&!/[\x00-\x08\x0b-\x1f\x7f]/.test(value),'invalid_playlist_description');
    }
    if(request.operation==='playlist_append') {request.arguments.playlist_id=readID(request.arguments.playlist_id);request.arguments.song_id=readID(request.arguments.song_id);}
    if(request.operation==='search') {if(Object.hasOwn(request.arguments,'offset'))check(typeof request.arguments.offset==='string'&&/^(0|[1-9][0-9]*)$/.test(request.arguments.offset)&&Number.isSafeInteger(Number(request.arguments.offset)),'invalid_search_offset');readText(request.arguments.keyword,400);check([...request.arguments.keyword].length<=100&&!request.arguments.keyword.startsWith('-'),'invalid_keyword');}
    if(request.operation==='cloud_songs'&&Object.hasOwn(request.arguments,'limit'))check(typeof request.arguments.limit==='string'&&/^(?:[1-9]|[1-4][0-9]|50)$/.test(request.arguments.limit),'invalid_read_arguments');
    if(request.operation==='cloud_songs'&&Object.hasOwn(request.arguments,'cursor'))check(validCloudCursor(request.arguments.cursor),'invalid_read_arguments');
    if(request.operation==='playlist_detail')request.arguments.playlist_id=readID(request.arguments.playlist_id);
    readContext={verification,metadataOnly,cover:request.operation==='playlist_cover'?{image:request.coverImage,md5:crypto.createHash('md5').update(request.coverImage).digest('hex'),tokenCount:0,receipts:[],offset:0,chunkAttempts:0}:null,isWrite,effectAttempted:false,operation:request.operation,arguments:request.arguments,results:{},refreshAttempted:false,refreshRejected:false,
      refreshCount:0,discoveryCount:0,consumeCount:0,failure:null,pageDeadline:performance.now()+25000};
  }
  check(typeof request.credential==='string'&&request.credential.length<=MAX*2,'invalid_credential_envelope');
  const raw=Buffer.from(request.credential,'base64');check(raw.length<=MAX&&raw.toString('base64')===request.credential,'invalid_credential_envelope');
  let credential;try{if(isRead){rememberSecret(raw.toString('utf8'));rememberSecret(request.credential);}credential=strictJSON(raw);}finally{raw.fill(0);request.credential='';}
  check(object(credential)&&credential.schema===1,'invalid_credential_envelope');
  if(credential.storage==='seed') {
    check(!isRead,'official_state_required');
    check(keys(credential,['schema','storage','app_id','private_key','device_id']) && typeof credential.app_id==='string' && /^[\x21-\x7e]{1,256}$/.test(credential.app_id) && typeof credential.private_key==='string' && /^[\r\n\x20-\x7e]{32,16384}$/.test(credential.private_key) && uuid(credential.device_id),'invalid_seed');
    for(const value of [credential.app_id,credential.private_key,credential.device_id])rememberSecret(value);
    store('.netease_mcp_device.json',JSON.stringify({deviceId:credential.device_id,createdAt:Date.now()}));
    store('.config/ncm-cli/config.json',JSON.stringify({appId:credential.app_id,privateKey:credential.private_key}));
    credential.private_key='';
  } else {
    check(keys(credential,['schema','storage','files'])&&credential.storage==='official'&&object(credential.files),'invalid_state');
    for(const [name,value] of Object.entries(credential.files)) {
      check(persistent.has(name)&&typeof value==='string','unknown_state_file');const bytes=Buffer.from(value,'base64');
      try{check(bytes.toString('base64')===value,'invalid_state_encoding');validateFile(name,bytes);store(name,bytes);}finally{bytes.fill(0);}
    }
    check(files.has('.netease_mcp_device.json')&&files.has('.config/ncm-cli/credentials.enc.json'),'incomplete_state');
    rememberPrivateState();
  }
  if(isRead) {
    let session;try{session=inspectSession();}catch{readFailure('contract_rejected',{reason:'session_state_invalid',stage:'session'});}
    if(!session||!session.present&&!session.refreshable) {
      if(session)readFailure('login_required');finish(request);process.exitCode=0;
    }
  }
  if(!finished) {
  const cli=path.resolve(__dirname,'../NetEase/dist/index.js');
  check(crypto.createHash('sha256').update(actualRead(cli)).digest('hex')===CLI_SHA,'official_cli_changed');
  installMemoryHome();installNetworkBoundary(request.operation!=='prepare'&&request.network_allowed===true);installOutputBoundary(request.call_id);
  const realExit=process.exit.bind(process);
  process.exit=code=>{exitCode=Number(code)||0;finish(request);realExit(readContext?0:exitCode);};
  process.on('beforeExit',()=>finish(request));
  process.on('uncaughtException',error=>{diagnostic?.error(error);exitCode=1;readFailure('contract_rejected');try{finish(request);}finally{realExit(readContext?0:1);}});
  process.on('unhandledRejection',error=>{diagnostic?.error(error);exitCode=1;readFailure('contract_rejected');try{finish(request);}finally{realExit(readContext?0:1);}});
  process.argv=[process.execPath,cli,...(isRead?['commands']:operationArgs[request.operation])];
  require(cli);
  }
} catch(error) {
  if(!diagnostic?.failed)diagnostic?.record('bridge','invalid_response');
  if(!finished){finished=true;frame({schema:1,event:'refused',code:'invalid_or_unavailable_runtime'});}
  process.exitCode=1;
} finally {
  // The CLI may exit synchronously; exit/beforeExit finish also clears the map.
  if(process.exitCode===1){for(const bytes of files.values())bytes.fill(0);files.clear();}
}
