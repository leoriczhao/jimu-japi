// libs_bignum.cpp - jass.bignum module
//
// builtin-japi ships a bignum helper that map scripts use for RSA style
// signature checks (external YDWE maps: scripts/util/RSA.lua):
//
//   local bignum = require "jass.bignum"
//   local e = bignum.new(bignum.bin("00010001"))   -- bin(): hex text -> bytes
//   local m = bignum.new(c)                        -- new(): big-endian bytes
//   local s = tostring(m:powmod(e, n))             -- lowercase hex, no padding
//   bignum.sha1("text")                            -- lowercase hex, no padding
//
// Implementation notes
//   * limbs are 32 bit, little endian, no trailing zero limbs.
//   * modular multiplication is the straightforward double-and-add (bit
//     scanning) variant. RSA-2048 signature work costs ~1s, which is fine:
//     the only consumer (hot-fix signature checks) is dormant in this port.
//   * tostring() and sha1() BOTH strip leading zero nibbles, so
//     "sha1(text) == tostring(encrypt(decrypt(sha1(text))))" holds exactly
//     (that equality is what RSA.lua:46 check_sign does).

#include <lua.hpp>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <cstdio>

namespace warcraft3::lua_engine::bignum {

typedef std::vector<uint32_t> num_t;

static void trim(num_t& a)
{
	while (!a.empty() && a.back() == 0) a.pop_back();
}

static int cmp_num(const num_t& a, const num_t& b)
{
	if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
	for (size_t i = a.size(); i-- > 0;) {
		if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
	}
	return 0;
}

static void add_num(const num_t& a, const num_t& b, num_t& r)
{
	size_t n = a.size() > b.size() ? a.size() : b.size();
	r.assign(n, 0);
	uint64_t carry = 0;
	for (size_t i = 0; i < n; ++i) {
		uint64_t s = carry;
		if (i < a.size()) s += a[i];
		if (i < b.size()) s += b[i];
		r[i] = (uint32_t)s;
		carry = s >> 32;
	}
	if (carry) r.push_back((uint32_t)carry);
}

// a >= b required.
static void sub_num(const num_t& a, const num_t& b, num_t& r)
{
	r.assign(a.size(), 0);
	int64_t borrow = 0;
	for (size_t i = 0; i < a.size(); ++i) {
		int64_t s = (int64_t)a[i] - (int64_t)(i < b.size() ? b[i] : 0) - borrow;
		if (s < 0) {
			s += (int64_t)1 << 32;
			borrow = 1;
		}
		else {
			borrow = 0;
		}
		r[i] = (uint32_t)s;
	}
	trim(r);
}

static void add_mod(num_t& a, const num_t& b, const num_t& m)
{
	num_t t;
	add_num(a, b, t);
	trim(t);
	if (cmp_num(t, m) >= 0) sub_num(t, m, a);
	else a = t;
}

static void reduce(num_t& a, const num_t& m)
{
	trim(a);
	while (cmp_num(a, m) >= 0) sub_num(a, m, a);
}

static void mul_mod(const num_t& a, const num_t& b, const num_t& m, num_t& r)
{
	r.clear();
	if (m.empty()) return;
	num_t base = a;
	reduce(base, m);
	for (size_t i = 0; i < b.size(); ++i) {
		uint32_t w = b[i];
		for (int bit = 0; bit < 32; ++bit) {
			if (w & 1u) add_mod(r, base, m);
			add_mod(base, base, m);
			w >>= 1;
		}
	}
	trim(r);
}

static void pow_mod(const num_t& base_in, const num_t& exp, const num_t& m, num_t& r)
{
	r.clear();
	if (m.empty()) return;
	if (m.size() == 1 && m[0] == 1) return;          // everything is 0 mod 1
	num_t base = base_in;
	reduce(base, m);

	r.push_back(1);   // m > 1 here, so 1 mod m == 1
	trim(r);

	// Exponent bits, most significant first.
	size_t top_limb = exp.size();
	while (top_limb > 0 && exp[top_limb - 1] == 0) --top_limb;
	if (top_limb == 0) {
		r.clear();
		r.push_back(1);
		return;
	}
	int top_bit = 31;
	while (top_bit > 0 && ((exp[top_limb - 1] >> top_bit) & 1u) == 0) --top_bit;

	for (size_t i = top_limb; i-- > 0;) {
		uint32_t w = exp[i];
		int high = (i == top_limb - 1) ? top_bit : 31;
		for (int bit = high; bit >= 0; --bit) {
			num_t sq;
			mul_mod(r, r, m, sq);
			r.swap(sq);
			if ((w >> bit) & 1u) {
				num_t t;
				mul_mod(r, base, m, t);
				r.swap(t);
			}
		}
	}
	trim(r);
}

static void from_bytes(num_t& out, const unsigned char* p, size_t n)
{
	out.clear();
	if (n == 0) return;
	out.resize((n + 3) / 4, 0);
	for (size_t i = 0; i < n; ++i) {
		unsigned char byte = p[n - 1 - i];            // most significant first
		out[i / 4] |= (uint32_t)byte << ((i % 4) * 8);
	}
	trim(out);
}

static std::string to_hex(const num_t& v)
{
	if (v.empty()) return std::string("0");
	std::string out;
	char buf[16];
	for (size_t i = v.size(); i-- > 0;) {
		if (i == v.size() - 1) snprintf(buf, sizeof(buf), "%x", v[i]);
		else snprintf(buf, sizeof(buf), "%08x", v[i]);
		out += buf;
	}
	return out;
}

static void from_hex(num_t& out, const char* s, size_t n)
{
	out.clear();
	std::string digits;
	digits.reserve(n);
	for (size_t i = 0; i < n; ++i) {
		char c = s[i];
		if (c >= '0' && c <= '9') digits += (char)(c - '0');
		else if (c >= 'a' && c <= 'f') digits += (char)(c - 'a' + 10);
		else if (c >= 'A' && c <= 'F') digits += (char)(c - 'A' + 10);
	}
	// digits are most significant first
	out.assign((digits.size() + 7) / 8, 0);
	for (size_t i = 0; i < digits.size(); ++i) {
		size_t pos = digits.size() - 1 - i;
		out[i / 8] |= (uint32_t)(unsigned char)digits[pos] << ((i % 8) * 4);
	}
	trim(out);
}

// ---------------------------------------------------------------- SHA-1

static uint32_t rol(uint32_t v, int bits)
{
	return (v << bits) | (v >> (32 - bits));
}

static void sha1_digest(const unsigned char* data, size_t len, unsigned char out[20])
{
	uint32_t h[5] = { 0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u };

	std::vector<unsigned char> msg(data, data + len);
	uint64_t bit_len = (uint64_t)len * 8;
	msg.push_back(0x80);
	while (msg.size() % 64 != 56) msg.push_back(0);
	for (int i = 7; i >= 0; --i) msg.push_back((unsigned char)((bit_len >> (i * 8)) & 0xFF));

	for (size_t off = 0; off + 64 <= msg.size(); off += 64) {
		uint32_t w[80];
		for (int i = 0; i < 16; ++i) {
			w[i] = ((uint32_t)msg[off + i * 4] << 24) | ((uint32_t)msg[off + i * 4 + 1] << 16) |
				((uint32_t)msg[off + i * 4 + 2] << 8) | (uint32_t)msg[off + i * 4 + 3];
		}
		for (int i = 16; i < 80; ++i) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);

		uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
		for (int i = 0; i < 80; ++i) {
			uint32_t f, k;
			if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999u; }
			else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1u; }
			else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
			else { f = b ^ c ^ d; k = 0xCA62C1D6u; }
			uint32_t tmp = rol(a, 5) + f + e + k + w[i];
			e = d; d = c; c = rol(b, 30); b = a; a = tmp;
		}
		h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
	}
	for (int i = 0; i < 5; ++i) {
		out[i * 4 + 0] = (unsigned char)(h[i] >> 24);
		out[i * 4 + 1] = (unsigned char)(h[i] >> 16);
		out[i * 4 + 2] = (unsigned char)(h[i] >> 8);
		out[i * 4 + 3] = (unsigned char)(h[i]);
	}
}

// ---------------------------------------------------------------- Lua glue

static const char* BN_MT = "jass.bignum.num";

struct BN {
	num_t v;
};

static BN* push_bn(lua_State* L, const num_t& v)
{
	BN* bn = (BN*)lua_newuserdata(L, sizeof(BN));
	new (&bn->v) num_t(v);
	luaL_getmetatable(L, BN_MT);
	lua_setmetatable(L, -2);
	return bn;
}

static BN* check_bn(lua_State* L, int idx)
{
	return (BN*)luaL_checkudata(L, idx, BN_MT);
}

static int bn_gc(lua_State* L)
{
	BN* bn = (BN*)lua_touserdata(L, 1);
	if (bn) bn->v.~num_t();
	return 0;
}

static int bn_tostring(lua_State* L)
{
	BN* bn = check_bn(L, 1);
	std::string hex = to_hex(bn->v);
	lua_pushlstring(L, hex.data(), hex.size());
	return 1;
}

static int bn_powmod(lua_State* L)
{
	BN* base = check_bn(L, 1);
	BN* exp = check_bn(L, 2);
	BN* mod = check_bn(L, 3);
	num_t r;
	pow_mod(base->v, exp->v, mod->v, r);
	push_bn(L, r);
	return 1;
}

static int bn_new(lua_State* L)
{
	int t = lua_type(L, 1);
	if (t == LUA_TUSERDATA) {
		BN* src = (BN*)luaL_testudata(L, 1, BN_MT);
		if (src) { push_bn(L, src->v); return 1; }
	}
	if (t == LUA_TNUMBER) {
		num_t v;
		lua_Integer n = luaL_checkinteger(L, 1);
		if (n < 0) n = -n;
		uint64_t x = (uint64_t)n;
		while (x) { v.push_back((uint32_t)x); x >>= 32; }
		push_bn(L, v);
		return 1;
	}
	size_t len = 0;
	const char* s = lua_tolstring(L, 1, &len);
	num_t v;
	if (s && len > 0) {
		// Optional "0x" prefix means hex text, otherwise big-endian bytes.
		if (len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
			from_hex(v, s + 2, len - 2);
		}
		else {
			from_bytes(v, (const unsigned char*)s, len);
		}
	}
	push_bn(L, v);
	return 1;
}

// bignum.bin(hex_text) -> big-endian bytes, width preserved
// ("00010001" is 4 bytes even though the leading zeros carry no value; RSA
// exponents/keys are fixed-width byte strings, so the input width is kept).
static int bn_bin(lua_State* L)
{
	size_t len = 0;
	const char* s = luaL_checklstring(L, 1, &len);

	size_t digits = 0;
	size_t start = 0;
	if (len > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) start = 2;
	for (size_t i = start; i < len; ++i) {
		char c = s[i];
		if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) ++digits;
	}

	num_t v;
	from_hex(v, s + start, len - start);
	std::string hex = to_hex(v);
	if (hex.size() % 2) hex.insert(hex.begin(), '0');

	auto nib = [](char c) -> int {
		if (c >= '0' && c <= '9') return c - '0';
		if (c >= 'a' && c <= 'f') return c - 'a' + 10;
		return c - 'A' + 10;
	};

	std::string bytes;
	size_t value_bytes = hex.size() / 2;
	size_t want_bytes = (digits + 1) / 2;
	if (want_bytes > value_bytes) bytes.assign(want_bytes - value_bytes, '\0');
	bytes.reserve(want_bytes);
	for (size_t i = 0; i + 1 < hex.size(); i += 2) {
		bytes += (char)((nib(hex[i]) << 4) | nib(hex[i + 1]));
	}
	lua_pushlstring(L, bytes.data(), bytes.size());
	return 1;
}

static int bn_sha1(lua_State* L)
{
	size_t len = 0;
	const char* s = luaL_checklstring(L, 1, &len);
	unsigned char digest[20];
	sha1_digest((const unsigned char*)(s ? s : ""), len, digest);

	char hex[41];
	for (int i = 0; i < 20; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
	hex[40] = '\0';

	// Strip leading zero nibbles: tostring() of a bignum does the same, which is
	// what makes RSA.lua's check_sign comparison work.
	const char* p = hex;
	while (p[0] == '0' && p[1] != '\0') ++p;
	lua_pushstring(L, p);
	return 1;
}

int open(lua_State* L)
{
	luaL_newmetatable(L, BN_MT);
	lua_pushcfunction(L, bn_gc);
	lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, bn_tostring);
	lua_setfield(L, -2, "__tostring");

	lua_newtable(L);                       // methods
	lua_pushcfunction(L, bn_powmod);
	lua_setfield(L, -2, "powmod");
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);                          // metatable

	lua_newtable(L);
	lua_pushcfunction(L, bn_new);
	lua_setfield(L, -2, "new");
	lua_pushcfunction(L, bn_bin);
	lua_setfield(L, -2, "bin");
	lua_pushcfunction(L, bn_sha1);
	lua_setfield(L, -2, "sha1");
	return 1;
}

}  // namespace warcraft3::lua_engine::bignum
