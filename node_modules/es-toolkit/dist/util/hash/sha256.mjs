// src/util/hash/sha256.ts
const K = new Int32Array([
	1116352408,
	1899447441,
	3049323471,
	3921009573,
	961987163,
	1508970993,
	2453635748,
	2870763221,
	3624381080,
	310598401,
	607225278,
	1426881987,
	1925078388,
	2162078206,
	2614888103,
	3248222580,
	3835390401,
	4022224774,
	264347078,
	604807628,
	770255983,
	1249150122,
	1555081692,
	1996064986,
	2554220882,
	2821834349,
	2952996808,
	3210313671,
	3336571891,
	3584528711,
	113926993,
	338241895,
	666307205,
	773529912,
	1294757372,
	1396182291,
	1695183700,
	1986661051,
	2177026350,
	2456956037,
	2730485921,
	2820302411,
	3259730800,
	3345764771,
	3516065817,
	3600352804,
	4094571909,
	275423344,
	430227734,
	506948616,
	659060556,
	883997877,
	958139571,
	1322822218,
	1537002063,
	1747873779,
	1955562222,
	2024104815,
	2227730452,
	2361852424,
	2428436474,
	2756734187,
	3204031479,
	3329325298
]);
const BASE64_URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
/**
* Computes the SHA-256 digest of a string and encodes it in Base64URL
* format without padding.
*
* The output is byte-identical to
* `crypto.hash('sha256', data, 'base64url')` in Node.js.
*
* @param data - The string to hash. Encoded as UTF-8 before hashing.
* @returns The 43-character Base64URL-encoded digest.
*/
function sha256(data) {
	const bytes = new TextEncoder().encode(data);
	const byteLength = bytes.length;
	const paddedLength = ((byteLength + 8 >> 6) + 1) * 64;
	const padded = new Uint8Array(paddedLength);
	padded.set(bytes);
	padded[byteLength] = 128;
	const view = new DataView(padded.buffer);
	view.setUint32(paddedLength - 8, Math.floor(byteLength / 536870912));
	view.setUint32(paddedLength - 4, byteLength << 3 >>> 0);
	let h0 = 1779033703;
	let h1 = -1150833019;
	let h2 = 1013904242;
	let h3 = -1521486534;
	let h4 = 1359893119;
	let h5 = -1694144372;
	let h6 = 528734635;
	let h7 = 1541459225;
	const w = /* @__PURE__ */ new Int32Array(64);
	for (let offset = 0; offset < paddedLength; offset += 64) {
		for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4) | 0;
		for (let i = 16; i < 64; i++) {
			const x = w[i - 15];
			const y = w[i - 2];
			const sigma0 = (x >>> 7 | x << 25) ^ (x >>> 18 | x << 14) ^ x >>> 3 | 0;
			const sigma1 = (y >>> 17 | y << 15) ^ (y >>> 19 | y << 13) ^ y >>> 10 | 0;
			w[i] = w[i - 16] + sigma0 + w[i - 7] + sigma1 | 0;
		}
		let a = h0;
		let b = h1;
		let c = h2;
		let d = h3;
		let e = h4;
		let f = h5;
		let g = h6;
		let h = h7;
		for (let i = 0; i < 64; i++) {
			const bigSigma1 = (e >>> 6 | e << 26) ^ (e >>> 11 | e << 21) ^ (e >>> 25 | e << 7);
			const ch = e & f ^ ~e & g;
			const t1 = h + bigSigma1 + ch + K[i] + w[i] | 0;
			const t2 = ((a >>> 2 | a << 30) ^ (a >>> 13 | a << 19) ^ (a >>> 22 | a << 10)) + (a & b ^ a & c ^ b & c) | 0;
			h = g;
			g = f;
			f = e;
			e = d + t1 | 0;
			d = c;
			c = b;
			b = a;
			a = t1 + t2 | 0;
		}
		h0 = h0 + a | 0;
		h1 = h1 + b | 0;
		h2 = h2 + c | 0;
		h3 = h3 + d | 0;
		h4 = h4 + e | 0;
		h5 = h5 + f | 0;
		h6 = h6 + g | 0;
		h7 = h7 + h | 0;
	}
	const digest = /* @__PURE__ */ new Uint8Array(32);
	const digestView = new DataView(digest.buffer);
	digestView.setInt32(0, h0);
	digestView.setInt32(4, h1);
	digestView.setInt32(8, h2);
	digestView.setInt32(12, h3);
	digestView.setInt32(16, h4);
	digestView.setInt32(20, h5);
	digestView.setInt32(24, h6);
	digestView.setInt32(28, h7);
	let result = "";
	for (let i = 0; i < 30; i += 3) {
		const n = digest[i] << 16 | digest[i + 1] << 8 | digest[i + 2];
		result += BASE64_URL_ALPHABET[n >>> 18 & 63] + BASE64_URL_ALPHABET[n >>> 12 & 63] + BASE64_URL_ALPHABET[n >>> 6 & 63] + BASE64_URL_ALPHABET[n & 63];
	}
	const n = digest[30] << 8 | digest[31];
	result += BASE64_URL_ALPHABET[n >>> 10 & 63] + BASE64_URL_ALPHABET[n >>> 4 & 63] + BASE64_URL_ALPHABET[n << 2 & 63];
	return result;
}
export { sha256 };
