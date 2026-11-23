#pragma once

#include <cstdint>

namespace warcraft3::japi {

	// Install CStatBar vtable hooks (idempotent, version-guarded for 1.27a).
	bool install_stat_bar_hooks();

	// Register bridge handlers and real JASS natives for native HP/MP bar control.
	void InitializeStatBar();

	// Reset all per-map stat bar customizations (called on map reboot / SimulateMapBoot).
	void clear_stat_bar_map_state();

	// Bridge dispatch handlers
	uint32_t EXSetManaBarEnabled_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetManaBarEnabled_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetManaBarColor_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetManaBarHeight_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetManaBarOffsetY_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitManaBarColor_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitManaBarVisible_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitHPBarColor_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitHPBarScale_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitHPBarVisible_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitTypeHPBarStyle_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetPlayerHPBarColor_handler(const uint32_t* args, size_t nargs);
	uint32_t EXResetUnitHPBar_handler(const uint32_t* args, size_t nargs);
	uint32_t EXResetAllStatBars_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetOffscreenBarCull_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetOffscreenBarCull_handler(const uint32_t* args, size_t nargs);

} // namespace warcraft3::japi
