#include "console.h"

#ifdef _DEBUG
#include <windows.h>

#include "utils.h"
#endif

void ConfigureConsole() {
#ifdef _DEBUG
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
#endif
}
