#include <Disks/DiskObjectStorage/MetadataStorages/PlainRewritable/UndoWithRetries.h>
#include <Disks/DiskObjectStorage/MetadataStorages/UndoWithRetries.h>

namespace ProfileEvents
{
    extern const Event DiskPlainRewritableUndoStageRetries;
}

namespace DB
{

void undoWithRetries(const LoggerPtr & log, std::string_view description, const std::function<void()> & stage)
{
    undoWithRetries(log, ProfileEvents::DiskPlainRewritableUndoStageRetries, description, stage);
}

}
