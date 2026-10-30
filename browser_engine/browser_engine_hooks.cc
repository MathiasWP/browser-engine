#include "browser_engine/browser_engine_hooks.h"

#include "base/check.h"

namespace browser_engine {

namespace {
Hooks* g_hooks = nullptr;
}  // namespace

void SetHooks(Hooks* hooks) {
  CHECK(hooks);
  CHECK(!g_hooks);
  g_hooks = hooks;
}

Hooks* GetHooks() {
  return g_hooks;
}

}  // namespace browser_engine
