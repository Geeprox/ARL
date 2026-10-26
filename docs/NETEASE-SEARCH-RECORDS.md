# Search records projection: actual container evidence

ARL20 PID93978, UTC 2026-10-10 10:09:02–10, call 7D044CC3-3F17-41AC-88A8-9AB319D590ED.
The complete diagnostic packet decodes to code:number, subCode:null, message:null,
data:object; data contains recordCount:number and records:array. records has 20
object entries. The old search selector songs/list matches zero keys/arrays
(q=[0,0,0]), not two. The packet is complete; shape completeness is false because
o=9 reports field-limit and budget pruning. No actual item keys or scalar values
survived. Do not label the synthetic inner fields as captured provider data.

The only new product mapping is search $.data.records -> payload.songs via the
existing projectItem(song); $.data.recordCount -> search_page.total is unchanged.
Existing item mapping remains encryptedId ?? songId ?? id -> song_id, name -> name,
originalId -> the fixed music.163.com song URL, ar ?? artists -> metadata.artists,
al ?? album -> metadata.album, and boolean visible -> visible. These mappings
are verified with synthetic items here, not proven against the real records yet.
Unknown recording version/duration remain unknown; no fields or links are guessed.

The fixture reproduces the observed envelope/types/records length. Its count=21,
identifiers, titles, artists and albums are invented. It runs the pinned official
CLI with actual production request/HTTPS gates and network disabled by mocks.
Two negative cases reject competing songs+records and non-array records. The
existing exactly-one-key rule, count/ID/text/privacy checks remain enforced.

Selection of records is search-only. The successful playlist listing, detail,
track projection, pagination, identity and write code remain byte-identical.
No real request, native compile, credential access or installed change is made by
these tests. A real search after reviewed installation remains necessary.
