#include <Disks/DiskObjectStorage/MetadataStorages/UndoWithRetries.h>

#include <Common/DynamicDelay.h>
#include <Common/Exception.h>
#include <Common/logger_useful.h>

#include <base/sleep.h>
#include <base/types.h>

namespace DB
{

namespace ErrorCodes
{
    extern const int LOGICAL_ERROR;
}

namespace
{

/// A stage fails because the storage is unavailable, so the pause grows until the retries cost nothing.
constexpr double FIRST_PAUSE_MS = 100;
constexpr double MAX_PAUSE_MS = 5000;
constexpr double PAUSE_FACTOR = 2;
/// Every transaction that the storage is failing right now retries on the same schedule, so each pause is spread to
/// keep them from coming back at the same moment.
constexpr Int64 MAX_JITTER_MS = 100;

}

void undoWithRetries(const LoggerPtr & log, ProfileEvents::Event retries_event, std::string_view description, const std::function<void()> & stage)
{
    DynamicDelay pause;
    pause.setConfiguration(FIRST_PAUSE_MS, MAX_PAUSE_MS, PAUSE_FACTOR);

    for (size_t attempt = 1;; ++attempt)
    {
        try
        {
            stage();
            return;
        }
        catch (...)
        {
            if (getCurrentExceptionCode() == ErrorCodes::LOGICAL_ERROR)
                throw;

            ProfileEvents::increment(retries_event);
            tryLogCurrentException(log, fmt::format("Attempt {} to {} failed", attempt, description));

            sleepForMilliseconds(pause.getCurrentDelayWithJitter(0, MAX_JITTER_MS));
            pause.up();
        }
    }
}

}
