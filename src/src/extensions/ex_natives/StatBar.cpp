// StatBar.cpp — Native War3 1.27a CStatBar overhead healthbar & manabar customization
//
// Hooks four vtable slots on Game.dll's CStatBar (vt+0x08 Dtor, vt+0x68 Show,
// vt+0x74 SetUnit, vt+0x78 SetOther) without inline code patching.
//
// Architecture modeled on Hr0ffT/W3ManaBars (MIT), ported to War3 1.27a (build 7000)
// with all RVAs and struct field offsets verified by disassembly against 1.27a Game.dll,
// extended with per-unit / per-unit-type / per-player HP bar color, scale, visibility,
// and per-unit / global native overhead mana bar styling.

#include "StatBar.h"

#include <windows.h>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <unordered_map>

#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/version.h>
#include "debug_log.h"

namespace warcraft3::japi {

namespace {

	// ── Verified 1.27a (build 7000) Game.dll RVAs ──────────────────────────
	constexpr uintptr_t RVA_VT_STATBAR       = 0x0098F52C;
	constexpr uintptr_t RVA_STATBAR_DTOR     = 0x0038B310; // vt+0x08
	constexpr uintptr_t RVA_STATBAR_GETH     = 0x000BCDF0; // vt+0x1C
	constexpr uintptr_t RVA_STATBAR_ONUPDATE = 0x003A49C0; // vt+0x34
	constexpr uintptr_t RVA_STATBAR_HIDE     = 0x000B96B0; // vt+0x64
	constexpr uintptr_t RVA_STATBAR_SHOW     = 0x000BA100; // vt+0x68
	constexpr uintptr_t RVA_STATBAR_SETUNIT  = 0x003BD490; // vt+0x74
	constexpr uintptr_t RVA_STATBAR_SETOTHER = 0x003BE9A0; // vt+0x78
	constexpr uintptr_t RVA_GLOBAL_GAMEUI    = 0x00BE6350; // CGameUI* global singleton

	constexpr uintptr_t RVA_STATBAR_CTOR     = 0x00383F60; // CStatBar::CStatBar(parent, unit, type)
	constexpr uintptr_t RVA_SMEM_ALLOC       = 0x00120628; // SMemAlloc(size, file, line, flags)
	constexpr uintptr_t RVA_ALLOC_FILE       = 0x009941A0; // ".../War3/Source/UI/CStatBar.cpp"
	constexpr uintptr_t RVA_SET_FRAME_POINT  = 0x000BD8A0; // CLayoutFrame::SetPoint
	constexpr uintptr_t RVA_SET_HEIGHT       = 0x000BD7C0; // CLayoutFrame::SetHeight
	constexpr uintptr_t RVA_SET_WIDTH        = 0x000BD960; // CLayoutFrame::SetWidth
	constexpr uintptr_t RVA_SET_COLOR        = 0x000BFA30; // CSimpleTexture::SetColor
	constexpr uintptr_t RVA_MAX_MANA         = 0x0003AE60; // CUnit+0xB8 :: GetMaxMana(float*)

	// ── Verified 1.27a CStatBar & CUnit struct offsets ─────────────────────
	constexpr uint32_t SB_SIZE               = 0x158;
	constexpr size_t   OFS_RECT              = 0x44; // float[4]: bottom, left, top, right
	constexpr size_t   OFS_RECT_VALID        = 0x54; // int: non-zero when rect is valid
	constexpr size_t   OFS_WIDTH             = 0x58;
	constexpr size_t   OFS_HEIGHT            = 0x5C;
	constexpr size_t   OFS_PARENT            = 0x6C;
	constexpr size_t   OFS_LEVEL             = 0x84;
	constexpr size_t   OFS_WANT              = 0x90;
	constexpr size_t   OFS_SHOWN             = 0x94;
	constexpr size_t   OFS_FILL_TEX          = 0x134;
	constexpr size_t   OFS_TYPE              = 0x138;
	constexpr size_t   OFS_WIDGET            = 0x154;

	constexpr size_t   GAMEUI_OFS_WORLDFRAME = 0x3BC;
	constexpr size_t   WORLDFRAME_OFS_LAYOUT = 0xB4;

	constexpr size_t   UNIT_OFS_ID1          = 0x0C;
	constexpr size_t   UNIT_OFS_ID2          = 0x10;
	constexpr size_t   UNIT_OFS_TYPEID       = 0x30;
	constexpr size_t   UNIT_OFS_MANA         = 0xB8;
	constexpr size_t   UNIT_VT_GET_OWNER     = 0xEC;

	constexpr int      SB_TYPE_MANA_SMALL    = 4;
	constexpr int      SB_TYPE_HP_SMALL      = 5;
	constexpr float    VANILLA_HP_HEIGHT     = 0.004f;

	constexpr int      PT_TOPLEFT            = 0;
	constexpr int      PT_TOPRIGHT           = 2;
	constexpr int      PT_BOTTOMLEFT         = 6;
	constexpr int      PT_BOTTOMRIGHT        = 8;

	constexpr uint32_t DEFAULT_MANA_COLOR    = 0xFF2864FF; // crisp War3 mana blue (ARGB)
	constexpr float    DEFAULT_MANA_RATIO    = 0.75f;
	constexpr float    DEFAULT_MANA_OFFSET_Y = -0.001f;

	// ── Engine function pointer typedefs ───────────────────────────────────
	using AllocFn    = void* (__stdcall*)(uint32_t size, const char* file, int line, int flags);
	using CtorFn     = void* (__thiscall*)(void* mem, void* parent, void* unit, int type);
	using DtorFn     = void* (__thiscall*)(void* bar, int flags);
	using SetPointFn = void  (__thiscall*)(void* frame, int pt, void* rel, int relPt, float x, float y, int upd);
	using SetFloatFn = void  (__thiscall*)(void* frame, float val);
	using GetFloatFn = float (__thiscall*)(void* frame);
	using SetColorFn = void  (__thiscall*)(void* tex, const uint32_t* argb);
	using MaxManaFn  = void  (__thiscall*)(void* manaSubObj, float* outMaxMana);
	using SetPtrFn   = void  (__thiscall*)(void* bar, void* obj);
	using ShowHideFn = int   (__thiscall*)(void* frame);
	using OnUpdateFn = void  (__thiscall*)(void* bar, float dt);
	using GetOwnerFn = int   (__thiscall*)(void* unit);

	struct EngineFns {
		uintptr_t   gameBase      = 0;
		uintptr_t*  vtStatBar     = nullptr;
		AllocFn     alloc         = nullptr;
		const char* allocFile     = nullptr;
		CtorFn      ctor          = nullptr;
		SetPointFn  setFramePoint = nullptr;
		SetFloatFn  setHeight     = nullptr;
		SetFloatFn  setWidth      = nullptr;
		GetFloatFn  getHeight     = nullptr;
		SetColorFn  setColor      = nullptr;
		MaxManaFn   maxMana       = nullptr;
		OnUpdateFn  origOnUpdate  = nullptr;
		ShowHideFn  origHide      = nullptr;
		ShowHideFn  origShow      = nullptr;
		DtorFn      origDtor      = nullptr;
		SetPtrFn    origSetUnit   = nullptr;
		SetPtrFn    origSetOther  = nullptr;
		bool        ready         = false;
	};

	EngineFns g_fn;

	// ── Customization state ────────────────────────────────────────────────
	struct UnitStyle {
		bool     hasHpColor    = false;
		uint32_t hpColor       = 0;
		bool     hasScale      = false;
		float    scaleX        = 1.0f;
		float    scaleY        = 1.0f;
		bool     hasHpVisible  = false;
		bool     hpVisible     = true;
		bool     hasManaColor  = false;
		uint32_t manaColor     = 0;
		int8_t   manaVisMode   = 0; // 0 = inherit global, 1 = force show, -1 = force hide
	};

	struct UnitTypeStyle {
		bool     hasHpColor    = false;
		uint32_t hpColor       = 0;
		bool     hasScale      = false;
		float    scaleX        = 1.0f;
		float    scaleY        = 1.0f;
	};

	struct TrackedBar {
		void*    manaBar           = nullptr;
		float    origWidth         = 0.03f;
		float    appliedWidth      = -1.0f;
		float    appliedHeight     = -1.0f;
		float    appliedManaY      = 0.0f;
		float    appliedManaHeight = -1.0f;
		uint32_t appliedManaColor  = 0;
		uint16_t staleFrames       = 0;
		bool     hiddenByUs        = false;
		bool     engineWantedShow  = false;
	};

	bool     g_manaEnabled     = false;
	bool     g_offscreenCull   = false;
	uint32_t g_manaColor       = DEFAULT_MANA_COLOR;
	float    g_manaHeightRatio = DEFAULT_MANA_RATIO;
	float    g_manaOffsetY     = DEFAULT_MANA_OFFSET_Y;

	std::unordered_map<void*, TrackedBar>        g_trackedBars;
	std::unordered_map<uint64_t, UnitStyle>      g_unitStyles;
	std::unordered_map<uint32_t, UnitTypeStyle>  g_typeStyles;
	std::unordered_map<int, uint32_t>            g_playerColors; // playerIndex -> ARGB

	// ── Helpers ────────────────────────────────────────────────────────────
	inline bool is_overhead_hp_bar(void* bar)
	{
		if (!bar) return false;
		auto* b = static_cast<uint8_t*>(bar);
		void* parent = *reinterpret_cast<void**>(b + OFS_PARENT);
		int   type   = *reinterpret_cast<int*>(b + OFS_TYPE);
		return parent == nullptr && type == SB_TYPE_HP_SMALL;
	}

	inline uint64_t unit_uid(void* unit)
	{
		if (!unit) return 0;
		auto* u = static_cast<const uint8_t*>(unit);
		uint32_t id1 = *reinterpret_cast<const uint32_t*>(u + UNIT_OFS_ID1);
		uint32_t id2 = *reinterpret_cast<const uint32_t*>(u + UNIT_OFS_ID2);
		return (static_cast<uint64_t>(id1) << 32) | id2;
	}

	inline uint32_t unit_type_id(void* unit)
	{
		if (!unit) return 0;
		return *reinterpret_cast<const uint32_t*>(static_cast<const uint8_t*>(unit) + UNIT_OFS_TYPEID);
	}

	inline int unit_owner_index(void* unit)
	{
		if (!unit) return -1;
		uintptr_t* vt = *reinterpret_cast<uintptr_t**>(unit);
		if (!vt) return -1;
		auto fn = reinterpret_cast<GetOwnerFn>(vt[UNIT_VT_GET_OWNER / sizeof(uintptr_t)]);
		if (!fn) return -1;
		return fn(unit);
	}

	inline float get_unit_max_mana(void* unit)
	{
		if (!unit || !g_fn.maxMana) return 0.0f;
		float out = 0.0f;
		g_fn.maxMana(static_cast<uint8_t*>(unit) + UNIT_OFS_MANA, &out);
		return out;
	}

	inline float clamp_f(float v, float lo, float hi)
	{
		if (v < lo) return lo;
		if (v > hi) return hi;
		return v;
	}

	struct EffectiveStyle {
		bool     hasHpColor    = false;
		uint32_t hpColor       = 0;
		float    scaleX        = 1.0f;
		float    scaleY        = 1.0f;
		bool     hpHidden      = false;
		bool     wantMana      = false;
		uint32_t manaColor     = DEFAULT_MANA_COLOR;
	};

	EffectiveStyle resolve_style(void* unit)
	{
		EffectiveStyle eff;
		eff.wantMana  = g_manaEnabled;
		eff.manaColor = g_manaColor;
		if (!unit) {
			eff.wantMana = false;
			return eff;
		}

		// Layer 1: player-level HP bar color
		if (!g_playerColors.empty()) {
			int pid = unit_owner_index(unit);
			auto it = g_playerColors.find(pid);
			if (it != g_playerColors.end() && it->second != 0) {
				eff.hasHpColor = true;
				eff.hpColor    = it->second;
			}
		}

		// Layer 2: unit-type style
		if (!g_typeStyles.empty()) {
			uint32_t tid = unit_type_id(unit);
			auto it = g_typeStyles.find(tid);
			if (it != g_typeStyles.end()) {
				if (it->second.hasHpColor) {
					eff.hasHpColor = true;
					eff.hpColor    = it->second.hpColor;
				}
				if (it->second.hasScale) {
					eff.scaleX = it->second.scaleX;
					eff.scaleY = it->second.scaleY;
				}
			}
		}

		// Layer 3: per-unit override (highest priority)
		if (!g_unitStyles.empty()) {
			uint64_t uid = unit_uid(unit);
			auto it = g_unitStyles.find(uid);
			if (it != g_unitStyles.end()) {
				const UnitStyle& us = it->second;
				if (us.hasHpColor) {
					eff.hasHpColor = true;
					eff.hpColor    = us.hpColor;
				}
				if (us.hasScale) {
					eff.scaleX = us.scaleX;
					eff.scaleY = us.scaleY;
				}
				if (us.hasHpVisible) {
					eff.hpHidden = !us.hpVisible;
				}
				if (us.hasManaColor) {
					eff.manaColor = us.manaColor;
				}
				if (us.manaVisMode > 0) {
					eff.wantMana = true;
				} else if (us.manaVisMode < 0) {
					eff.wantMana = false;
				}
			}
		}

		if (eff.hpHidden) {
			eff.wantMana = false;
		}
		return eff;
	}

	void hide_mana_bar(void* manaBar, bool detachUnit)
	{
		if (!manaBar) return;
		auto* mb = static_cast<uint8_t*>(manaBar);
		*reinterpret_cast<int*>(mb + OFS_WANT) = 0;
		g_fn.origHide(manaBar);
		if (detachUnit) {
			g_fn.origSetUnit(manaBar, nullptr);
		}
	}

	void anchor_mana_bar(void* manaBar, void* hpBar, float offsetY)
	{
		g_fn.setFramePoint(manaBar, PT_TOPLEFT,  hpBar, PT_BOTTOMLEFT,  0.0f, offsetY, 1);
		g_fn.setFramePoint(manaBar, PT_TOPRIGHT, hpBar, PT_BOTTOMRIGHT, 0.0f, offsetY, 1);
	}

	void* ensure_mana_bar(TrackedBar& rec, void* hpBar, void* unit)
	{
		if (rec.manaBar) {
			if (std::fabs(rec.appliedManaY - g_manaOffsetY) > 1e-6f) {
				anchor_mana_bar(rec.manaBar, hpBar, g_manaOffsetY);
				rec.appliedManaY = g_manaOffsetY;
			}
			return rec.manaBar;
		}

		void* mem = g_fn.alloc(SB_SIZE, g_fn.allocFile, 0, 0);
		if (!mem) return nullptr;

		void* mb = g_fn.ctor(mem, hpBar, unit, SB_TYPE_MANA_SMALL);
		if (!mb) return nullptr;

		// Match parent HP bar frame level and anchor directly underneath it.
		auto* hb = static_cast<uint8_t*>(hpBar);
		auto* m  = static_cast<uint8_t*>(mb);
		*reinterpret_cast<int*>(m + OFS_LEVEL) = *reinterpret_cast<int*>(hb + OFS_LEVEL);
		anchor_mana_bar(mb, hpBar, g_manaOffsetY);

		rec.manaBar      = mb;
		rec.appliedManaY = g_manaOffsetY;

		static bool loggedFirstMana = false;
		if (!loggedFirstMana) {
			loggedFirstMana = true;
			char buf[160];
			snprintf(buf, sizeof(buf),
			         "StatBar: first native manaBar created (hpBar=0x%08X manaBar=0x%08X unit=0x%08X)",
			         (unsigned)(uintptr_t)hpBar, (unsigned)(uintptr_t)mb, (unsigned)(uintptr_t)unit);
			japi_log::sync_write(buf);
		}
		return mb;
	}

	void apply_bar_customization(void* bar, void* unit)
	{
		static bool loggedFirstHp = false;
		if (!loggedFirstHp && unit) {
			loggedFirstHp = true;
			char buf[160];
			snprintf(buf, sizeof(buf),
			         "StatBar: first overhead HP bar intercepted (bar=0x%08X unit=0x%08X typeId=0x%08X)",
			         (unsigned)(uintptr_t)bar, (unsigned)(uintptr_t)unit, (unsigned)unit_type_id(unit));
			japi_log::sync_write(buf);
		}

		auto* hb = static_cast<uint8_t*>(bar);
		TrackedBar& rec = g_trackedBars[bar];
		if (*reinterpret_cast<int*>(hb + OFS_SHOWN) != 0) {
			rec.engineWantedShow = true;
		}

		// Capture vanilla width whenever CPreselectUI writes a fresh value
		float curWidth = *reinterpret_cast<float*>(hb + OFS_WIDTH);
		if (rec.appliedWidth < 0.0f || std::fabs(curWidth - rec.appliedWidth) > 1e-6f) {
			if (curWidth > 0.0f) {
				rec.origWidth = curWidth;
			}
		}

		EffectiveStyle eff = resolve_style(unit);

		// 1. Apply HP bar color override (after origSetUnit wrote vanilla green->red)
		if (eff.hasHpColor) {
			void* fillTex = *reinterpret_cast<void**>(hb + OFS_FILL_TEX);
			if (fillTex) {
				uint32_t col = eff.hpColor;
				g_fn.setColor(fillTex, &col);
			}
		}

		// 2. Apply HP bar width / height scaling without compounding
		float targetW = rec.origWidth * eff.scaleX;
		float targetH = VANILLA_HP_HEIGHT * eff.scaleY;
		if (rec.appliedWidth < 0.0f || std::fabs(curWidth - targetW) > 1e-6f) {
			g_fn.setWidth(bar, targetW);
			rec.appliedWidth = targetW;
		}
		float curHeight = *reinterpret_cast<float*>(hb + OFS_HEIGHT);
		if (rec.appliedHeight < 0.0f || std::fabs(curHeight - targetH) > 1e-6f) {
			g_fn.setHeight(bar, targetH);
			rec.appliedHeight = targetH;
		}

		// 3. Apply HP bar visibility override
		if (eff.hpHidden) {
			rec.hiddenByUs = true;
			*reinterpret_cast<int*>(hb + OFS_WANT) = 0;
			g_fn.origHide(bar);
			if (rec.manaBar) {
				hide_mana_bar(rec.manaBar, unit == nullptr);
			}
			return;
		}
		if (rec.hiddenByUs) {
			rec.hiddenByUs = false;
			if (rec.engineWantedShow) {
				*reinterpret_cast<int*>(hb + OFS_WANT) = 1;
				g_fn.origShow(bar);
			}
		}

		// 4. Native overhead mana bar (steady-state cached: zero layout/color churn)
		bool showMana = eff.wantMana && unit != nullptr && get_unit_max_mana(unit) > 0.0f;
		if (showMana) {
			void* mb = ensure_mana_bar(rec, bar, unit);
			if (mb) {
				float hpH = g_fn.getHeight(bar);
				if (hpH <= 0.0f) hpH = targetH;
				float targetManaH = hpH * g_manaHeightRatio;
				if (rec.appliedManaHeight < 0.0f || std::fabs(rec.appliedManaHeight - targetManaH) > 1e-6f) {
					g_fn.setHeight(mb, targetManaH);
					rec.appliedManaHeight = targetManaH;
				}

				// Update fill ratio from unit mana
				g_fn.origSetUnit(mb, unit);

				// Apply custom mana bar color only when changed (SetUnit type=4 preserves color)
				auto* m = static_cast<uint8_t*>(mb);
				if (rec.appliedManaColor != eff.manaColor) {
					void* mFillTex = *reinterpret_cast<void**>(m + OFS_FILL_TEX);
					if (mFillTex) {
						uint32_t col = eff.manaColor;
						g_fn.setColor(mFillTex, &col);
						rec.appliedManaColor = eff.manaColor;
					}
				}

				*reinterpret_cast<int*>(m + OFS_WANT) = 1;
				if (*reinterpret_cast<int*>(hb + OFS_SHOWN) != 0 &&
				    *reinterpret_cast<int*>(m + OFS_SHOWN) == 0) {
					g_fn.origShow(mb);
				}
			}
		} else if (rec.manaBar) {
			hide_mana_bar(rec.manaBar, unit == nullptr);
		}
	}

	// Zero-overhead WorldFrame viewport edge-clamp check (4 float compares, zero raycasts).
	// CPreselectUI::UpdatePosition (0x3782A0..0x3782DE) clamps off-screen / behind-console
	// bars onto WorldFrame's edges right before calling bar->Show().
	bool is_bar_clamped_to_edge(void* bar)
	{
		if (!g_fn.gameBase) return false;
		auto* hb = static_cast<const uint8_t*>(bar);
		if (*reinterpret_cast<const int*>(hb + OFS_RECT_VALID) == 0) return false;

		void* gameUI = *reinterpret_cast<void**>(g_fn.gameBase + RVA_GLOBAL_GAMEUI);
		if (!gameUI) return false;
		void* worldFrame = *reinterpret_cast<void**>(static_cast<uint8_t*>(gameUI) + GAMEUI_OFS_WORLDFRAME);
		if (!worldFrame) return false;

		const uint8_t* wfLayout = static_cast<const uint8_t*>(worldFrame) + WORLDFRAME_OFS_LAYOUT;
		if (*reinterpret_cast<const int*>(wfLayout + OFS_RECT_VALID) == 0) return false;

		const float* wr = reinterpret_cast<const float*>(wfLayout + OFS_RECT); // [bottom, left, top, right]
		const float* br = reinterpret_cast<const float*>(hb + OFS_RECT);       // [bottom, left, top, right]

		constexpr float kEps = 0.0006f;
		const float barH = br[2] - br[0];
		return (br[0] <= wr[0] + kEps) ||        // clamped to bottom (top of console HUD)
		       (br[1] <= wr[1] + kEps) ||        // clamped to left screen edge
		       (br[3] >= wr[3] - kEps) ||        // clamped to right screen edge
		       (br[2] + barH >= wr[2] - kEps);   // clamped to top (under resource bar)
	}

	// Re-apply customization immediately to all live tracked bars (0ms visual update).
	void refresh_tracked_bars(uint64_t filterUid = 0)
	{
		if (!g_fn.ready) return;
		for (auto& kv : g_trackedBars) {
			void* bar = kv.first;
			if (!bar) continue;
			auto* hb = static_cast<uint8_t*>(bar);
			void* unit = *reinterpret_cast<void**>(hb + OFS_WIDGET);
			if (!unit) continue;
			if (filterUid != 0 && unit_uid(unit) != filterUid) continue;

			// Call origSetUnit first so restoring vanilla color works immediately
			g_fn.origSetUnit(bar, unit);
			apply_bar_customization(bar, unit);
		}
	}

	// ── Vtable hooks (__fastcall matches x86 __thiscall with dummy edx) ────
	void* __fastcall Dtor_hook(void* bar, void* /*edx*/, int flags)
	{
		// Remove from tracking before engine destroys child frames (manaBar).
		g_trackedBars.erase(bar);
		return g_fn.origDtor(bar, flags);
	}

	void __fastcall OnUpdate_hook(void* bar, void* /*edx*/, float dt)
	{
		g_fn.origOnUpdate(bar, dt);

		// Zero-overhead phantom stuck-bar purifier:
		// Active on-screen units have CPreselectUI::UpdatePosition call bar->Show()
		// every render frame. If a visible overhead bar goes 4+ advancing frames without
		// a Show() heartbeat, 3D culling dropped it without calling Hide() -> hide now.
		if (g_offscreenCull && dt > 0.0f && is_overhead_hp_bar(bar)) {
			auto* hb = static_cast<uint8_t*>(bar);
			if (*reinterpret_cast<int*>(hb + OFS_SHOWN) != 0) {
				auto it = g_trackedBars.find(bar);
				if (it != g_trackedBars.end()) {
					if (++it->second.staleFrames >= 4) {
						it->second.staleFrames = 0;
						it->second.engineWantedShow = false;
						*reinterpret_cast<int*>(hb + OFS_WANT) = 0;
						g_fn.origHide(bar);
					}
				}
			}
		}
	}

	int __fastcall Hide_hook(void* bar, void* /*edx*/)
	{
		if (is_overhead_hp_bar(bar)) {
			auto it = g_trackedBars.find(bar);
			if (it != g_trackedBars.end()) {
				it->second.engineWantedShow = false;
				it->second.staleFrames = 0;
			}
		}
		return g_fn.origHide(bar);
	}

	int __fastcall Show_hook(void* bar, void* /*edx*/)
	{
		if (is_overhead_hp_bar(bar)) {
			TrackedBar& rec = g_trackedBars[bar];
			rec.engineWantedShow = true;
			rec.staleFrames = 0;

			auto* hb = static_cast<uint8_t*>(bar);
			const bool wasShown = (*reinterpret_cast<int*>(hb + OFS_SHOWN) != 0);

			void* unit = *reinterpret_cast<void**>(hb + OFS_WIDGET);
			if (unit) {
				EffectiveStyle eff = resolve_style(unit);
				if (eff.hpHidden) {
					rec.hiddenByUs = true;
					*reinterpret_cast<int*>(hb + OFS_WANT) = 0;
					g_fn.origHide(bar);
					return 1;
				}
			}

			// On Call #2 inside CPreselectUI::UpdatePosition (0x378350, right after
			// SetAbsPoint + UpdateLayout), wasShown is 1 and [bar+0x44..0x50] holds the
			// fresh screen rect before D3D renders. Suppress edge-clamped bars with 0 flicker.
			if (g_offscreenCull && wasShown && is_bar_clamped_to_edge(bar)) {
				g_fn.origHide(bar);
				return 1;
			}
		}

		int ret = g_fn.origShow(bar);

		// Ensure attached mana bar shows synchronously on the first frame
		auto it = g_trackedBars.find(bar);
		if (it != g_trackedBars.end() && it->second.manaBar) {
			auto* m = static_cast<uint8_t*>(it->second.manaBar);
			if (*reinterpret_cast<int*>(m + OFS_WANT) != 0 &&
			    *reinterpret_cast<int*>(m + OFS_SHOWN) == 0) {
				g_fn.origShow(it->second.manaBar);
			}
		}
		return ret;
	}

	void __fastcall SetUnit_hook(void* bar, void* /*edx*/, void* unit)
	{
		g_fn.origSetUnit(bar, unit);
		if (is_overhead_hp_bar(bar)) {
			apply_bar_customization(bar, unit);
		}
	}

	void __fastcall SetOther_hook(void* bar, void* /*edx*/, void* widget)
	{
		g_fn.origSetOther(bar, widget);
		// When widget is a CUnit, SetOther already called SetUnit(unit) via vtable.
		// When widget is non-unit or null, ensure any child mana bar is hidden.
		if (is_overhead_hp_bar(bar)) {
			auto it = g_trackedBars.find(bar);
			if (it != g_trackedBars.end() && it->second.manaBar) {
				if (!widget) {
					hide_mana_bar(it->second.manaBar, true);
				} else {
					auto* hb = static_cast<uint8_t*>(bar);
					void* bound = *reinterpret_cast<void**>(hb + OFS_WIDGET);
					if (!bound) {
						hide_mana_bar(it->second.manaBar, true);
					}
				}
			}
		}
	}

	bool patch_vtable_slot(uintptr_t* slot, uintptr_t value)
	{
		DWORD oldProt = 0;
		if (!VirtualProtect(slot, sizeof(uintptr_t), PAGE_READWRITE, &oldProt)) {
			return false;
		}
		*slot = value;
		DWORD dummy = 0;
		VirtualProtect(slot, sizeof(uintptr_t), oldProt, &dummy);
		return true;
	}

	void* resolve_unit_ptr(jass::jhandle_t unitHandle)
	{
		if (!unitHandle) return nullptr;
		uintptr_t obj = handle_to_object(unitHandle);
		if (!obj) return nullptr;
		return reinterpret_cast<void*>(obj);
	}

} // anonymous namespace

bool install_stat_bar_hooks()
{
	if (g_fn.ready) return true;

	war3_searcher& s = get_war3_searcher();
	if (s.get_version() != version_127a) {
		char buf[128];
		snprintf(buf, sizeof(buf), "StatBar: skipped (unsupported War3 version %u, need 1.27a)",
		         (unsigned)s.get_version());
		japi_log::sync_write(buf);
		return false;
	}

	uintptr_t base = s.base();
	auto* vt = reinterpret_cast<uintptr_t*>(base + RVA_VT_STATBAR);

	// Strict sanity check: verify all 6 target vtable slots match 1.27a Game.dll
	const uintptr_t expDtor     = base + RVA_STATBAR_DTOR;
	const uintptr_t expOnUpdate = base + RVA_STATBAR_ONUPDATE;
	const uintptr_t expHide     = base + RVA_STATBAR_HIDE;
	const uintptr_t expShow     = base + RVA_STATBAR_SHOW;
	const uintptr_t expSetUnit  = base + RVA_STATBAR_SETUNIT;
	const uintptr_t expSetOther = base + RVA_STATBAR_SETOTHER;

	if (vt[0x08 / 4] != expDtor ||
	    vt[0x34 / 4] != expOnUpdate ||
	    vt[0x64 / 4] != expHide ||
	    vt[0x68 / 4] != expShow ||
	    vt[0x74 / 4] != expSetUnit ||
	    vt[0x78 / 4] != expSetOther) {
		char buf[256];
		snprintf(buf, sizeof(buf),
		         "StatBar: vtable mismatch at 0x%08X (dtor=0x%08X upd=0x%08X show=0x%08X setUnit=0x%08X setOther=0x%08X)",
		         (unsigned)(uintptr_t)vt,
		         (unsigned)(vt[0x08 / 4] - base),
		         (unsigned)(vt[0x34 / 4] - base),
		         (unsigned)(vt[0x68 / 4] - base),
		         (unsigned)(vt[0x74 / 4] - base),
		         (unsigned)(vt[0x78 / 4] - base));
		japi_log::sync_write(buf);
		return false;
	}

	g_fn.gameBase      = base;
	g_fn.vtStatBar     = vt;
	g_fn.alloc         = reinterpret_cast<AllocFn>(base + RVA_SMEM_ALLOC);
	g_fn.allocFile     = reinterpret_cast<const char*>(base + RVA_ALLOC_FILE);
	g_fn.ctor          = reinterpret_cast<CtorFn>(base + RVA_STATBAR_CTOR);
	g_fn.setFramePoint = reinterpret_cast<SetPointFn>(base + RVA_SET_FRAME_POINT);
	g_fn.setHeight     = reinterpret_cast<SetFloatFn>(base + RVA_SET_HEIGHT);
	g_fn.setWidth      = reinterpret_cast<SetFloatFn>(base + RVA_SET_WIDTH);
	g_fn.getHeight     = reinterpret_cast<GetFloatFn>(base + RVA_STATBAR_GETH);
	g_fn.setColor      = reinterpret_cast<SetColorFn>(base + RVA_SET_COLOR);
	g_fn.maxMana       = reinterpret_cast<MaxManaFn>(base + RVA_MAX_MANA);
	g_fn.origOnUpdate  = reinterpret_cast<OnUpdateFn>(expOnUpdate);
	g_fn.origHide      = reinterpret_cast<ShowHideFn>(expHide);
	g_fn.origShow      = reinterpret_cast<ShowHideFn>(expShow);
	g_fn.origDtor      = reinterpret_cast<DtorFn>(expDtor);
	g_fn.origSetUnit   = reinterpret_cast<SetPtrFn>(expSetUnit);
	g_fn.origSetOther  = reinterpret_cast<SetPtrFn>(expSetOther);

	bool ok = true;
	ok = ok && patch_vtable_slot(&vt[0x08 / 4], reinterpret_cast<uintptr_t>(&Dtor_hook));
	ok = ok && patch_vtable_slot(&vt[0x34 / 4], reinterpret_cast<uintptr_t>(&OnUpdate_hook));
	ok = ok && patch_vtable_slot(&vt[0x64 / 4], reinterpret_cast<uintptr_t>(&Hide_hook));
	ok = ok && patch_vtable_slot(&vt[0x68 / 4], reinterpret_cast<uintptr_t>(&Show_hook));
	ok = ok && patch_vtable_slot(&vt[0x74 / 4], reinterpret_cast<uintptr_t>(&SetUnit_hook));
	ok = ok && patch_vtable_slot(&vt[0x78 / 4], reinterpret_cast<uintptr_t>(&SetOther_hook));

	if (!ok) {
		japi_log::sync_write("StatBar: VirtualProtect failed while patching CStatBar vtable");
		return false;
	}

	g_fn.ready = true;
	char buf[160];
	snprintf(buf, sizeof(buf), "StatBar: 1.27a CStatBar vtable hooked (base=0x%08X vt=0x%08X)",
	         (unsigned)base, (unsigned)(uintptr_t)vt);
	japi_log::sync_write(buf);
	return true;
}

void clear_stat_bar_map_state()
{
	g_manaEnabled     = false;
	g_offscreenCull   = false;
	g_manaColor       = DEFAULT_MANA_COLOR;
	g_manaHeightRatio = DEFAULT_MANA_RATIO;
	g_manaOffsetY     = DEFAULT_MANA_OFFSET_Y;
	g_unitStyles.clear();
	g_typeStyles.clear();
	g_playerColors.clear();

	if (g_fn.ready) {
		refresh_tracked_bars(0);
	}
}

// ── Core C++ implementations (shared by bridge handlers & JASS natives) ────

static void impl_set_mana_bar_enabled(bool enable)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	g_manaEnabled = enable;
	refresh_tracked_bars(0);
}

static bool impl_get_mana_bar_enabled()
{
	return g_manaEnabled;
}

static void impl_set_mana_bar_color(uint32_t argb)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	g_manaColor = argb ? argb : DEFAULT_MANA_COLOR;
	refresh_tracked_bars(0);
}

static void impl_set_mana_bar_height(float ratio)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	g_manaHeightRatio = clamp_f(ratio, 0.1f, 4.0f);
	refresh_tracked_bars(0);
}

static void impl_set_mana_bar_offset_y(float offsetY)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	g_manaOffsetY = clamp_f(offsetY, -0.05f, 0.05f);
	refresh_tracked_bars(0);
}

static void impl_set_unit_mana_bar_color(jass::jhandle_t unitHandle, uint32_t argb)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	UnitStyle& us = g_unitStyles[uid];
	us.hasManaColor = (argb != 0);
	us.manaColor    = argb;
	refresh_tracked_bars(uid);
}

static void impl_set_unit_mana_bar_visible(jass::jhandle_t unitHandle, bool visible)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	UnitStyle& us = g_unitStyles[uid];
	us.manaVisMode = visible ? 1 : -1;
	refresh_tracked_bars(uid);
}

static void impl_set_unit_hp_bar_color(jass::jhandle_t unitHandle, uint32_t argb)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	UnitStyle& us = g_unitStyles[uid];
	us.hasHpColor = (argb != 0);
	us.hpColor    = argb;
	refresh_tracked_bars(uid);
}

static void impl_set_unit_hp_bar_scale(jass::jhandle_t unitHandle, float scaleX, float scaleY)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	UnitStyle& us = g_unitStyles[uid];
	us.hasScale = true;
	us.scaleX   = clamp_f(scaleX, 0.1f, 5.0f);
	us.scaleY   = clamp_f(scaleY, 0.1f, 5.0f);
	refresh_tracked_bars(uid);
}

static void impl_set_unit_hp_bar_visible(jass::jhandle_t unitHandle, bool visible)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	UnitStyle& us = g_unitStyles[uid];
	us.hasHpVisible = true;
	us.hpVisible    = visible;
	refresh_tracked_bars(uid);
}

static void impl_set_unit_type_hp_bar_style(uint32_t unitTypeId, uint32_t argb, float scaleX, float scaleY)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	if (!unitTypeId) return;
	UnitTypeStyle& ts = g_typeStyles[unitTypeId];
	ts.hasHpColor = (argb != 0);
	ts.hpColor    = argb;
	if (scaleX > 0.0f && scaleY > 0.0f) {
		ts.hasScale = true;
		ts.scaleX   = clamp_f(scaleX, 0.1f, 5.0f);
		ts.scaleY   = clamp_f(scaleY, 0.1f, 5.0f);
	} else {
		ts.hasScale = false;
		ts.scaleX   = 1.0f;
		ts.scaleY   = 1.0f;
	}
	refresh_tracked_bars(0);
}

static void impl_set_player_hp_bar_color(int playerIndex, uint32_t argb)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	if (playerIndex < 0 || playerIndex >= 16) return;
	if (argb == 0) {
		g_playerColors.erase(playerIndex);
	} else {
		g_playerColors[playerIndex] = argb;
	}
	refresh_tracked_bars(0);
}

static void impl_reset_unit_hp_bar(jass::jhandle_t unitHandle)
{
	void* unit = resolve_unit_ptr(unitHandle);
	if (!unit) return;
	uint64_t uid = unit_uid(unit);
	g_unitStyles.erase(uid);
	refresh_tracked_bars(uid);
}

// ── Bridge dispatch handlers ───────────────────────────────────────────────

uint32_t EXSetManaBarEnabled_handler(const uint32_t* a, size_t)
{
	impl_set_mana_bar_enabled(a[0] != 0);
	return 0;
}

uint32_t EXGetManaBarEnabled_handler(const uint32_t*, size_t)
{
	return impl_get_mana_bar_enabled() ? 1 : 0;
}

uint32_t EXSetManaBarColor_handler(const uint32_t* a, size_t)
{
	impl_set_mana_bar_color(a[0]);
	return 0;
}

uint32_t EXSetManaBarHeight_handler(const uint32_t* a, size_t)
{
	impl_set_mana_bar_height(jass::from_real(a[0]));
	return 0;
}

uint32_t EXSetManaBarOffsetY_handler(const uint32_t* a, size_t)
{
	impl_set_mana_bar_offset_y(jass::from_real(a[0]));
	return 0;
}

uint32_t EXSetUnitManaBarColor_handler(const uint32_t* a, size_t)
{
	impl_set_unit_mana_bar_color(a[0], a[1]);
	return 0;
}

uint32_t EXSetUnitManaBarVisible_handler(const uint32_t* a, size_t)
{
	impl_set_unit_mana_bar_visible(a[0], a[1] != 0);
	return 0;
}

uint32_t EXSetUnitHPBarColor_handler(const uint32_t* a, size_t)
{
	impl_set_unit_hp_bar_color(a[0], a[1]);
	return 0;
}

uint32_t EXSetUnitHPBarScale_handler(const uint32_t* a, size_t)
{
	impl_set_unit_hp_bar_scale(a[0], jass::from_real(a[1]), jass::from_real(a[2]));
	return 0;
}

uint32_t EXSetUnitHPBarVisible_handler(const uint32_t* a, size_t)
{
	impl_set_unit_hp_bar_visible(a[0], a[1] != 0);
	return 0;
}

uint32_t EXSetUnitTypeHPBarStyle_handler(const uint32_t* a, size_t)
{
	impl_set_unit_type_hp_bar_style(a[0], a[1], jass::from_real(a[2]), jass::from_real(a[3]));
	return 0;
}

uint32_t EXSetPlayerHPBarColor_handler(const uint32_t* a, size_t)
{
	impl_set_player_hp_bar_color(static_cast<int>(a[0]), a[1]);
	return 0;
}

uint32_t EXResetUnitHPBar_handler(const uint32_t* a, size_t)
{
	impl_reset_unit_hp_bar(a[0]);
	return 0;
}

uint32_t EXResetAllStatBars_handler(const uint32_t*, size_t)
{
	clear_stat_bar_map_state();
	return 0;
}

uint32_t EXSetOffscreenBarCull_handler(const uint32_t* a, size_t)
{
	if (!g_fn.ready) install_stat_bar_hooks();
	g_offscreenCull = (a[0] != 0);
	return 0;
}

uint32_t EXGetOffscreenBarCull_handler(const uint32_t*, size_t)
{
	return g_offscreenCull ? 1 : 0;
}

// ── Real JASS native adapters (jass::japi_add) ─────────────────────────────

static void __cdecl EXSetManaBarEnabled_native(jass::jboolean_t en) { impl_set_mana_bar_enabled(en != 0); }
static jass::jboolean_t __cdecl EXGetManaBarEnabled_native() { return impl_get_mana_bar_enabled() ? jass::jtrue : jass::jfalse; }
static void __cdecl EXSetManaBarColor_native(jass::jinteger_t argb) { impl_set_mana_bar_color((uint32_t)argb); }
static void __cdecl EXSetManaBarHeight_native(const jass::jreal_t* r) { if (r) impl_set_mana_bar_height(jass::from_real(*r)); }
static void __cdecl EXSetManaBarOffsetY_native(const jass::jreal_t* y) { if (y) impl_set_mana_bar_offset_y(jass::from_real(*y)); }
static void __cdecl EXSetUnitManaBarColor_native(jass::jhandle_t u, jass::jinteger_t argb) { impl_set_unit_mana_bar_color(u, (uint32_t)argb); }
static void __cdecl EXSetUnitManaBarVisible_native(jass::jhandle_t u, jass::jboolean_t vis) { impl_set_unit_mana_bar_visible(u, vis != 0); }
static void __cdecl EXSetUnitHPBarColor_native(jass::jhandle_t u, jass::jinteger_t argb) { impl_set_unit_hp_bar_color(u, (uint32_t)argb); }
static void __cdecl EXSetUnitHPBarScale_native(jass::jhandle_t u, const jass::jreal_t* sx, const jass::jreal_t* sy) {
	if (sx && sy) impl_set_unit_hp_bar_scale(u, jass::from_real(*sx), jass::from_real(*sy));
}
static void __cdecl EXSetUnitHPBarVisible_native(jass::jhandle_t u, jass::jboolean_t vis) { impl_set_unit_hp_bar_visible(u, vis != 0); }
static void __cdecl EXSetUnitTypeHPBarStyle_native(jass::jinteger_t tid, jass::jinteger_t argb, const jass::jreal_t* sx, const jass::jreal_t* sy) {
	if (sx && sy) impl_set_unit_type_hp_bar_style((uint32_t)tid, (uint32_t)argb, jass::from_real(*sx), jass::from_real(*sy));
}
static void __cdecl EXSetPlayerHPBarColor_native(jass::jinteger_t pid, jass::jinteger_t argb) { impl_set_player_hp_bar_color((int)pid, (uint32_t)argb); }
static void __cdecl EXResetUnitHPBar_native(jass::jhandle_t u) { impl_reset_unit_hp_bar(u); }
static void __cdecl EXResetAllStatBars_native() { clear_stat_bar_map_state(); }
static void __cdecl EXSetOffscreenBarCull_native(jass::jboolean_t en) { if (!g_fn.ready) install_stat_bar_hooks(); g_offscreenCull = (en != 0); }
static jass::jboolean_t __cdecl EXGetOffscreenBarCull_native() { return g_offscreenCull ? jass::jtrue : jass::jfalse; }

void InitializeStatBar()
{
	install_stat_bar_hooks();

	jass::japi_add((uintptr_t)EXSetManaBarEnabled_native,     "EXSetManaBarEnabled",     "(B)V");
	jass::japi_add((uintptr_t)EXGetManaBarEnabled_native,     "EXGetManaBarEnabled",     "()B");
	jass::japi_add((uintptr_t)EXSetManaBarColor_native,       "EXSetManaBarColor",       "(I)V");
	jass::japi_add((uintptr_t)EXSetManaBarHeight_native,      "EXSetManaBarHeight",      "(R)V");
	jass::japi_add((uintptr_t)EXSetManaBarOffsetY_native,     "EXSetManaBarOffsetY",     "(R)V");
	jass::japi_add((uintptr_t)EXSetUnitManaBarColor_native,   "EXSetUnitManaBarColor",   "(Hunit;I)V");
	jass::japi_add((uintptr_t)EXSetUnitManaBarVisible_native, "EXSetUnitManaBarVisible", "(Hunit;B)V");
	jass::japi_add((uintptr_t)EXSetUnitHPBarColor_native,     "EXSetUnitHPBarColor",     "(Hunit;I)V");
	jass::japi_add((uintptr_t)EXSetUnitHPBarScale_native,     "EXSetUnitHPBarScale",     "(Hunit;RR)V");
	jass::japi_add((uintptr_t)EXSetUnitHPBarVisible_native,   "EXSetUnitHPBarVisible",   "(Hunit;B)V");
	jass::japi_add((uintptr_t)EXSetUnitTypeHPBarStyle_native, "EXSetUnitTypeHPBarStyle", "(IIRR)V");
	jass::japi_add((uintptr_t)EXSetPlayerHPBarColor_native,   "EXSetPlayerHPBarColor",   "(II)V");
	jass::japi_add((uintptr_t)EXResetUnitHPBar_native,        "EXResetUnitHPBar",        "(Hunit;)V");
	jass::japi_add((uintptr_t)EXResetAllStatBars_native,      "EXResetAllStatBars",      "()V");
	jass::japi_add((uintptr_t)EXSetOffscreenBarCull_native,   "EXSetOffscreenBarCull",   "(B)V");
	jass::japi_add((uintptr_t)EXGetOffscreenBarCull_native,   "EXGetOffscreenBarCull",   "()B");
}

} // namespace warcraft3::japi
