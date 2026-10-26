import fs from 'node:fs';
export async function load(url,context,nextLoad) {
 if(url.endsWith('/NetEase/node_modules/node-fetch/src/index.js'))return {format:'module',shortCircuit:true,source:fs.readFileSync(new URL('./NetEasePlaylistMetadataFetch.mjs',import.meta.url),'utf8')};
 return nextLoad(url,context);
}
