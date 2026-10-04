#pragma once

#include <Common/Logger.h>
#include <Common/ProfileEvents.h>

#include <functional>
#include <string_view>

namespace DB
{

/** Repeats a step of an `undo` until it succeeds, counting every repetition in `retries_event`.
  * A step that keeps failing holds the thread. `LOGICAL_ERROR` is not repeated: asking again repairs no invariant.
  */
void undoWithRetries(const LoggerPtr & log, ProfileEvents::Event retries_event, std::string_view description, const std::function<void()> & stage);

}
